# Answers for Stones

This says what was done about `CHANGES-FOR-STONES.md`, and what was not.
It is written for whoever works on Stones next. Two items were turned
down. Before you ask for either of them again, read the reasons here.

Everything below is in the library as of the commit that brings each
part of it. `nix develop -c make check` passes. That is 158 properties,
32 examples in the application suite, and two input tests.

## Done

### 1. A command can be lifted into another event type

`Cmd`, `Sub` and `Transition` each have a `Functor` instance.
`Transition` has a `Bifunctor` instance as well. A part of an
application that owns its event type now goes inside one that owns
another:

```haskell
inTab :: TabId -> Transition Game GameEvent -> Transition State Event
inTab tab = bimap (inGame tab) (InTab tab)
```

`Data.Bifunctor` is in base, so the second instance cost nothing. It
maps the state as well as the events, which is what a part with a state
of its own needs.

Before you use this, read the next item. Mapping leaves the names of
jobs and subscriptions alone. Names are shared by everything the loop
runs.

### 1a. Qualifying the names, which was not in the list

Nobody asked for this. It is the thing that bites Stones first, because
Stones has a game per tab.

Names are global to the loop. `keyed` replaces a name rather than
putting something in front of it. So a parent that wraps a child command
in `keyed "tab-3"` collapses every name the child used into one name.
Two tabs that both ask for `"preview"` are one `"preview"`. Each cancels
the other's work, and it does so silently, because that is what a name
means. Subscriptions are worse. Two subscriptions under one name are one
subscription.

So there are two new functions:

```haskell
qualifying     :: Text -> Cmd event -> Cmd event
qualifyingSubs :: Text -> [Sub event] -> [Sub event]
```

Each one puts a prefix in front of the names it finds, with a `/`
between the two. Each leaves an unnamed job unnamed. A part of an
application that can be there more than once says which one it is:

```haskell
qualifying (tabName tab) (fmap (InTab tab) (gameCmd game))

subscriptions state =
  concat [ qualifyingSubs (tabName tab) (fmap (InTab tab) <$> gameSubs game)
         | (tab, game) <- tabs state
         ]
```

There is a test for the reason as well as for the mechanism. When the
names are qualified, two parts that both name a job `"answer"` both
finish. When they are not qualified, one of them loses its work.

### 2. A command can be opened up

```haskell
jobsOf :: Cmd event -> [(Maybe Text, Producer event IO ())]
```

This is as the request specified it. A test runs a job with
`Pipes.toListM` and reads its events. It also sees the name the job runs
under, which is what says that `keyed` or `qualifying` was applied.

There is no function that runs a whole command. The request gave the
reason: such a function hangs on the first `stream`.

`Sub` gained `subKey` and `subRun` for the same reason on the other
side. Without them a parent cannot rename a child's subscriptions, and a
test cannot say what one is.

### 3. A controller added to a widget can be kept

```haskell
addOwnedController
  :: (Gtk.IsWidget widget, Gtk.IsEventController controller, MonadIO m)
  => widget -> controller -> m controller
```

It is exported from `GI.Gtk.Declarative.EventController`, which is where
the request said to look for it. It reads the address while the value is
still the caller's, adds the controller, and takes a fresh reference
back from the address. Those are the three lines the library already had
in private.

The test adds a click gesture to a drawing area with it. Then it sets a
name through the reference that came back, connects a handler through
it, and reads both back off the widget.

Your redesign is still the better one for a custom widget that is
subscribed to more than once. Connect the handlers once, and read a
mutable box for the callback. This function is for the cases where that
design does not fit.

### 5. `CustomKeep` says what it does

The haddock beside the constructor says two things now. A custom widget
that answers `CustomKeep` is still a `Modify`. The properties, the
classes, the slots and the references are applied whatever it says, and
what it skips is the custom action alone.

Nobody wrote the `Eq` on collected attributes. Your own note had it
right: more work than the sentence, and worth less.

### 6. The menus take a `Vector`

The module haddock and the documentation page say so, with the
comprehension spelled out. The sentence is a little wider than the
request asked for, because this is not only about the menus. The
children and the attributes of every widget in this library are a
`Vector`. `OverloadedLists` covers a literal and leaves a comprehension
alone, everywhere.

### 4, in part. When a reference is resolved

Three places say it now: the haddock in
`GI.Gtk.Declarative.References`, the haddock on `reference`, and the
documentation page. The name is looked up on the next turn of the main
loop. A running application never notices. A caller that reads the
property straight after building the tree must let the loop turn first.

That is the first of the two things the request offered. The second is
below.

### 8. The rows and the toggle group

Four of the five are in. `AdwPreferencesGroup` and `AdwActionRow` are
containers, with `rowPrefix`, `rowSuffix` and a `headerSuffix` slot.
`AdwToggleGroup` is a widget of its own, with `Toggle`,
`ToggleGroupParams` and `toggleGroup`, in the shape of the model views.
`AdwComboRow` waits. It belongs beside the model views rather than
beside the rows, because what it needs is a model.

Two notes on the shape of it.

`AdwSwitchRow` and `AdwSpinRow` needed nothing. They are leaf widgets
with properties, so `widget Adw.SwitchRow [#title := "Sound", #active
:= on]` worked already. A list box takes them, and so does a
preferences group. The documentation says so now.

A toggle group is not a container in this library's sense. `AdwToggle`
is a plain GObject rather than a `GtkWidget`, and `IsContainer` hands
its instance a `Gtk.Widget`. So the toggles are data rather than
children, matched from one render to the next by a name each.

The reason given for the item was right, and this widget goes one step
further than the reason asked for. `active` is read back off the group
before it is set. A group that says something the markup does not is
put back, however it got there. The tests cover a click that GTK
refuses, through `tests/gui-toggle.sh`, and a group that drifted some
other way, through a patch that changes nothing.

## Item 9, for you to decide on

This is not a request from Stones. It is what item 8 turned up, written
here because the answer is yours rather than ours.

The toggle button that does not hold together is one case of something
general. A property is compared declared-to-declared in this library.
`updateProperties` reads what the markup said last time and what it
says now. It sets the widget only where the two differ. It never asks
the widget what it holds.

So any widget that a person can change drifts the same way. A
`GtkEntry` whose `#text` comes from the state is the common one. The
markup says "hello", somebody types, and the entry says "hello world".
The update declines the change, or rounds it, or is slow, and the next
markup says "hello" again. The declared value did not change, so
nothing is set, and the entry keeps the typing. Switch rows, spin rows
and check buttons are all shaped like that.

The general fix is to compare the declared value with the value the
widget holds, rather than with the declared value of the render before.
`CollectedProperty` carries `Eq setValue` already, so the comparison is
writable.

Two things stand in the way, and both are about cost.

A property has to be readable for this, and not every property is.
`AttrOp` covers properties that are set only, so the fix applies to the
ones that can be got and leaves the rest as they are.

It costs a read per patched property per patch. Cellar's grid patches
about six hundred cells, and it is the program that measures this
library. The cost is small per property and it is not nothing at six
hundred, so the numbers have to come before the change.

A smaller version is available, and it is perhaps the right one. Add an
attribute, rather than changing every property. `holding (#text := s)`
says that this one property is a value the widget must not drift from.
A program then pays for the properties it knows about, and pays nothing
anywhere else.

The toggle group does the widget-shaped version of this already, for
one property of one widget. That was cheap, because a toggle group has
one value to read.

## Not done

### 4, the other half. Trying the lookup before deferring

The request offers a second option. Try the lookup where it stands.
Defer it only after that lookup finds nothing. A bar built after the
view it names then works at once.

It does not work at once. The test that asked for it still needs the
loop to turn.

`resolveReferences` runs inside `create`. A widget is not attached to
its parent until `create` returns. The parent puts it there, and a tree
is built from the leaves up. So at the moment the tab bar resolves its
references, the tab bar has no parent. `findNamed` walks up to the tab
bar itself. It searches the tab bar's own subtree and nothing else. The view it names is a sibling that does not exist yet. The eager
lookup finds nothing, the deferred one runs, and the property is set on
the next turn, exactly as it is today.

An eager lookup succeeds in one case only. That case is a patch, where
the tree is attached already. Such a rule is worse than no rule at all.
It reads like this. On a first render the property is set a turn later.
On a patch it is set at once. Which of the two happens is not something
the caller says. A test against that is
harder to write than a test against the rule there is now.

If the wait ever costs something real, rather than being a surprise, the
fix is not here. The fix is a hook this library does not have. That hook
resolves the references once, at the end of the whole tree's `create`,
rather than inside the `create` of each widget. It is a change to every
widget kind. So far, nothing needs it.

What to do in Stones: keep the turn of the loop in the test. Before you
read the property, let the loop turn once. The suite in this repository
does the same thing for the same reason. See
`GI.Gtk.Declarative.Adwaita.ReferenceTest`, where every property lets
the loop turn before it reads the tab bar's view.

### 7. `NoFieldSelectors` on the module that defines `App`

This one is turned down. The cost is a major version for every reader of
those fields. The gain is three names, in modules that import the loop
unqualified. There is a one-line answer already, and it needs nothing
from this library:

```haskell
import GI.Gtk.Declarative.App.Simple hiding (update, view, inputs, initialState)
```

That line gives a program its own `update` and `view`. Record
construction and record update keep working. The selectors stay for
anybody who wants them. Nobody is broken. The examples in this
repository still write `update'` and `view'`, which is a habit rather
than a constraint.

If this library ever makes a breaking release for another reason,
`NoFieldSelectors` can ride along with it. It is not worth a release of
its own.

## One thing to know that nobody asked about

`defaultApp` arrived with the subscriptions work. Build an `App` from
it, rather than by naming the constructor:

```haskell
run defaultApp { view = view', update = update', initialState = start }
```

A record built by naming the constructor must name every field, so each
new field breaks everybody. Built this way, the next field this library
adds is one that nobody has to write.
