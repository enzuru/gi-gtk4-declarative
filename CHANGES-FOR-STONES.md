# Changes this library needs, for Stones

Stones is a Go board in a libadwaita window. It lives in the `stones`
repository beside this one, under the GPL, and it is built on all three
packages here: the markup, the application loop, and the libadwaita
widgets. It draws its board with a custom widget. It holds a game per tab in an
`AdwTabView`, and it talks to a GNU Go process for each tab.

Seven items. Items 1 and 2 changed the shape of Stones, and they are
the two worth doing first. Items 3 to 5 each cost a working day. Items
6 and 7 are small.

Nothing here is a defect that loses data or crashes a program. Items 4
and 5 are places where the documentation and the behavior disagree,
which is the closest any of them comes.

## Ground rules

- `nix develop --offline -c make check` passes today. Keep it passing.
  It is the gate for every item here.
- Items 1, 2 and 6 change the application loop and the menus. Items 3,
  4 and 5 change the markup package.
- Each item names its tests. Write them in the style of the suite that
  is already there.
- Add no dependency to any package. Every item is written with what the
  packages already import.

## 1. A command cannot be lifted into another event type

`Cmd` has no `Functor` instance. Neither has `Transition`, and neither
has `Sub`.

This is the one that changed how Stones is built. Stones has a game per
tab. Each game wants its own event type, and the window wants to wrap
one in the tab it came from:

```haskell
-- What Stones wanted to write.
inTab :: TabId -> Transition Session SessionEvent -> Transition State Event
inTab tab step = fmap (InTab tab) ...
```

A component that owns its own event type is how this architecture
composes. Elm does it with `Cmd.map`, and every library in that family
has the same function under some name. Without it the two layers cannot
meet, so Stones does not use `Cmd` between them at all. Its per-game
update answers with a bare `IO` action instead:

```haskell
data Step = Step
  { stepSession :: Session
  , stepAsk     :: Maybe (IO Reply)
  }
```

The window then wraps that action in `perform` itself. It works, and it
is a wheel that this library should be turning.

What to do. Add three instances to `GI.Gtk.Declarative.App.Simple`.
Both `>->` and `Pipes.map` are already imported there.

```haskell
instance Functor Cmd where
  fmap f (Cmd jobs) =
    Cmd [ job { jobRun = jobRun job >-> Pipes.map f } | job <- jobs ]

instance Functor Sub where
  fmap f subscription =
    subscription { subRun = subRun subscription >-> Pipes.map f }

instance Functor (Transition state) where
  fmap f (Transition state cmd) = Transition state (fmap f cmd)
  fmap _ Exit                   = Exit
```

A `Bifunctor` for `Transition` would map the state as well. It is worth
having, and the `Functor` is what unblocks the composition.

Test. Add a property to the application suite. Build a command from
`emit`, map a constructor over it, run the loop with it, and assert
that the wrapped events arrive. Do the same for a `stream` command,
because a mapped pipe has to keep yielding more than once.

## 2. Nothing can run a command, so nothing can test one

`Cmd` is exported without its constructor, and the loop is the only
thing that can run one. So a test can ask what an update returns, and
it cannot ask what that command does.

This is the other half of why Stones does not use `Cmd` between its
layers. Its window answers with `Maybe (IO [Event])`, and its tests run
that action and read the events back. Those tests are the ones that say
a tab closing stops the GNU Go that was playing in it. They could not
be written against a `Cmd`.

What to do. Export one function from
`GI.Gtk.Declarative.App.Simple` that opens a command up:

```haskell
-- | The jobs of a command, each with the name it runs under.
jobsOf :: Cmd event -> [(Maybe Text, Producer event IO ())]
jobsOf (Cmd jobs) = [ (jobKey job, jobRun job) | job <- jobs ]
```

That is enough. A test runs a producer with `Pipes.toListM` and gets
the events. It can also see the name a job runs under, which is what
says `keyed` was applied. A job from `stream` may never end, so the
haddock has to say that the caller has to know what it asked for.

Do not add a function that runs a whole command and collects
everything. It would hang on the first `stream`.

Test. A property that builds `keyed "x" (emit [1, 2])`, reads it back
with `jobsOf`, and asserts both the name and the events.

## 3. A controller added to a widget cannot be kept

`Gtk.widgetAddController` disowns the pointer it is given. A custom
widget that adds a controller and then keeps it in its internal state
is reading a value it no longer owns. haskell-gi says so at run time:

```
Callstack for the unsafe access to the pointer:
  withManagedPtr, called at ./Data/GI/Base/Signals.hs:229:5
The pointer was disowned at:
  disownObject, called at ./GI/Gtk/Objects/Widget.hs:6203:20
  widgetAddController, called at src/Stones/Goban.hs:108:5
```

This library already knows the answer. `freshController` in
`GI.Gtk.Declarative.Attributes.Internal` reads the address out while
the value is still its own, and `ownedController` takes a fresh
reference back from it. Neither is exported.

Stones hit this while adding a click gesture and a motion controller to
its board. It could not keep them, so it redesigned around the problem:
the handlers are connected once when the widget is made, they read a
mutable box for the callback, and subscribing writes that box. The
design is better for other reasons, and it was not a free choice.

What to do. Export one function. `GI.Gtk.Declarative.EventController`
is where a custom widget author will look for it.

```haskell
-- | Add a controller to a widget, and answer with a reference the
-- caller still owns.
--
-- A widget takes a controller over when it is given one, so a value
-- kept after that is a value nobody owns. This hands back one that is
-- owned, for a custom widget that has to reach its controllers again.
addOwnedController
  :: (Gtk.IsWidget widget, Gtk.IsEventController controller)
  => widget
  -> controller
  -> IO controller
```

The body is the three lines `freshController` already has: read the
address with `withManagedPtr`, add the controller, and take a new
reference from the address with `newObject`.

The private `addController` in `Attributes.Internal` has that name
already and does something else, which is why this one needs a name of
its own.

Test. Add a property that makes a drawing area and adds a gesture with
this function. Connect a handler through the value it answered with,
and read the controller count back off the widget. Without the fix, the
same test through `Gtk.widgetAddController` prints the warning above.

## 4. A reference is resolved a turn later than the documentation says

`GI.Gtk.Declarative.References` says this:

> A reference is resolved once the tree is built, and again after each
> patch.

That reads as though it happens before `create` returns. It does not.
`resolveReferences` in `Attributes.Internal` defers the lookup with
`GLib.idleAdd`, so the property is set on the next turn of the main
loop.

The reason is sound. A bar is often built before the view it names, and
a lookup at that moment finds nothing.

Nothing in a running program notices, because a patch follows within
the first event. A test notices at once. Stones has a property that
builds its window and asks the tab bar which view it is showing. It
answered `Nothing` until the test was changed to turn the loop once
first.

What to do. Either of these, and the first is enough:

- Say it in the haddock. Two sentences: the name is looked up on the
  next turn of the main loop. A caller that reads the property straight
  after building the tree has to let the loop turn first.
- Try the lookup where it stands, and defer only when it finds nothing.
  A bar built after the view it names then works at once, and a bar
  built before it behaves as it does today.

Test. If you take the second option, add a property for it. Build a
container whose named widget comes first and whose reference comes
second, and assert the property is set before the loop turns.

## 5. CustomKeep does not keep

`CustomPatch` has three cases, and the middle one reads as though
answering `CustomKeep` means the patch does nothing:

```haskell
data CustomPatch widget internalState
  = CustomReplace
  | CustomModify (widget -> IO internalState)
  | CustomKeep
```

The `Patchable` instance for `CustomWidget` answers `Modify` whatever
`customPatch` said, as long as the properties can be modified. It has
to, because the properties, the classes, the slots and the references
all still need applying. `CustomKeep` only skips the custom action.

That is the right behavior. The name promises more than it delivers.
Stones wrote a test that asserted `Keep` for a board whose parameters
had not changed, and the test was wrong rather than the library.

What to do. Say it in the haddock for `CustomPatch`, next to
`CustomKeep`. One sentence: the widget's own state is left alone, and
the patch is still a `Modify`, because the attributes are patched
either way.

Answering `Keep` when the collected attributes are equal as well would
be truer to the name. `CollectedProperty` is a GADT that carries
`Eq setValue` and `Typeable setValue`, so an `Eq` instance for it is
writable. It is more work than the sentence and it is worth less.

Test. None needed for the sentence.

## 6. A menu section takes a vector and nothing else

`menuSection`, `subMenu`, `menuBar` and `menuButton` all take a
`Vector`. With `OverloadedLists` a list literal works and a list
comprehension does not:

```haskell
-- This compiles.
menuSection Nothing [menuItem "9x9" (New 9), menuItem "13x13" (New 13)]

-- This does not.
menuSection Nothing [ menuItem (label n) (New n) | n <- [9, 13, 19] ]
--     Couldn't match expected type 'Vector (MenuItem event)'
--                   with actual type '[MenuItem event]'
```

The error names the types and not the reason, and the reason is that
`OverloadedLists` covers literals and leaves comprehensions alone.

What to do. Say it in the haddock for the menu module. One sentence:
these take a `Vector`, so a list comprehension needs
`Vector.fromList` around it.

Taking any `Foldable` instead would read better and would cost more
than it is worth. A list literal under `OverloadedLists` would then
have no type to be, and every call site would need an annotation.

Test. None needed.

## 7. Three field names everybody wants, optional

`App` has fields called `update`, `view` and `initialState`. Those are
the three names a program most wants for its own functions. Every
example in this repository writes `update'` and `view'` for that
reason, and so does Stones.

With `NoFieldSelectors` on the module that defines `App`, a program
could keep its own `update` and `view` and still write:

```haskell
run defaultApp { update = update, view = view, initialState = start }
```

Record construction and update go by the constructor, so the field
names still work. What goes away is `update someApp` as a function. A
caller that wants that writes `someApp.update` with
`OverloadedRecordDot`, which this compiler has.

It is a breaking change for anybody reading those fields back. Stones
has one test that does, so the cost is real and small. Put it behind a
major version, or leave it.

Test. The examples are the test. If they compile with their primes
removed, it works.

## What Stones does by hand until items 1 and 2 land

Its per-game update in `Stones.Session` answers with a `Step`, which is
the new session and `Maybe (IO Reply)`. Its window update in
`Stones.App` answers with a `Doing`, which is the new state and
`Maybe (IO [Event])`. `update'` is a wrapper that turns the second into
a `Transition` with `stream`.

Both of those types exist because a `Cmd` cannot be mapped and cannot
be run. Both would go, and `Stones.Session` would answer with a
`Transition Session SessionEvent` that the window lifts.
