# Events

To react to user events in the graphical user interface, GTK lets you
connect callbacks to _signals_. This package takes a more declarative
approach, and talks about _events_ rather than signals. Widgets emit
_event values_, and these values can be mapped and transformed into
other values as the event propagates up the tree of widgets.

## Pure Event Handlers

When working with GTK widgets, we transform signals into event values
using event handlers. Much like [properties](properties.md), event
handlers for signals are declared in the attributes list, using the
`on` function.

``` haskell
data ButtonEvent = ButtonClicked

counterButton :: Widget ButtonEvent
counterButton =
  widget
    Button
      [ #label := "Click me!"
      , on #clicked ButtonClicked
      ]
```

Some signals in GTK carry extra information, supplied as extra
parameters to signal callbacks. This is supported in
gi-gtk-declarative as well, by passing those parameters to the event
handler function.

## Event Handlers with Arguments

Looking at `WidgetDirectionChangedCallback` in gi-gtk, the callback
type for the `direction-changed` signal, we see that it's a type
alias:

``` haskell
type WidgetDirectionChangedCallback = TextDirection -> IO Bool
```

In gi-gtk-declarative, when using a pure event handler, the type of
the event handler will be `TextDirection -> event`, where `event` is
the event data type of the widget. In the following example we declare
a button and emit an event when it's text direction changes. We map
the GTK-specific text direction value to our own type.

``` haskell
-- A custom type for text direction
data Dir = LTR | RTL

-- Our event data type
data MyEvent = TextDirectionSet Dir | TextDirectionCleared

textDirAwareEntry :: Widget MyEvent
textDirAwareEntry =
  widget Entry [on #directionChanged toEvent]
  where
    -- Map GTK 'TextDirection' values to our event type:
    toEvent TextDirectionLtr = TextDirectionSet LTR
    toEvent TextDirectionRtl = TextDirectionSet RTL
    toEvent _                = TextDirectionCleared
```

## Impure Event Handlers

When attaching an event handler to a widget signal, it's often
necessary to query the widget for its current property values.
Getting properties is not pure, so we need event handlers in `IO`.
Using the `onM` function instead of `on`, our event handler returns
the event as `IO event`. Also, the handler will take the widget itself
as an extra argument.

In the following example we attach an event handler to the `color-set`
signal. The event handler uses `getColorButtonRgba` to get the current
`RGBA` value from the `ColorButton` widget, and maps the
`ColorChanged` constructor over the IO action.


``` haskell
data ColorEvent = ColorChanged (Maybe RGBA)

colorButton :: RGBA -> Widget ColorEvent
colorButton color =
  widget
    ColorButton
    [ #title := "Selected color"
    , #rgba := color
    , onM #colorSet toColorEvent
    ]
  where
    toColorEvent :: ColorButton -> IO ColorEvent
    toColorEvent w = ColorChanged <$> getColorButtonRgba w
```

In case the underlying signal callback type has extra arguments, the
impure event handler will be a function of those arguments _and_ the
widget as the last argument. The translation can be described like this:

``` haskell
type SignalCallback =
     arg1
  -> arg2
  -> ...
  -> argN
  -> IO ()

type ImpureEventHandler =
     arg1
  -> arg2
  -> ...
  -> argN
  -> widget
  -> IO event
```

## Signal Handler Return Values

Some signal callbacks in GTK have return values other than `()`. It's
common that callbacks return a `Bool` value, determining whether to
propagate the event further or not. One example is
`WidgetFocusCallback`, the callback for the `focus` signal:

``` haskell
type WidgetFocusCallback = DirectionType -> IO Bool
```

In gi-gtk-declarative, the return value type of the event handler will
be a tuple of the callback return value and the event to emit. In the
case of the `focus` signal, a pure event handler type would be
`DirectionType -> (Bool, event)`. As described above, impure event
handlers return IO actions, and in the case of the `focus` signal the
type would be `DirectionType -> IO (Bool, event)`.

The translation to pure and impure event handlers can be described
like this:

``` haskell
type SignalCallback =
     arg1
  -> arg2
  -> ...
  -> argN
  -> IO a -- where 'a' is not '()'

type PureEventHandler =
     arg1
  -> arg2
  -> ...
  -> argN
  -> (a, event)

type ImpureEventHandler =
     arg1
  -> arg2
  -> ...
  -> argN
  -> widget -- also including the widget!
  -> IO (a, event)
```

## Functors

Widgets that emit events have `Functor` instances, meaning that you
can use regular `fmap` and friends to map event values using pure
functions.

As an example, say that we have another library provide a
`clickyButton` that emits `ButtonEvent`s.

``` haskell
data ButtonEvent = ButtonClicked

clickyButton :: Text -> Widget ButtonEvent
```

In our own widget declaration, we can use the clicky button to
increment or decrement some counter, by mapping the `ButtonClicked`
events to values of type `MyEvent`.

``` haskell
import Data.Functor (($>))

data MyEvent = Incr | Decr

incrDecrButtons :: Widget MyEvent
incrDecrButtons =
  container Box [#orientation := OrientationHorizontal]
    [ clickyButton "-1" $> Decr
    , clickyButton "+1" $> Incr
    ]
```

!!! note

    `(a $> b)` is equivalent to `(const b <$> a)`.

## Event Controllers

GTK 4 took keys, pointers, and gestures out of the widget's own signals
and put them in _event controllers_, which are objects you add to a
widget. The GTK 3 signals for this, `key-press-event` and
`button-press-event` among them, are gone.

The `GI.Gtk.Declarative.EventController` module gives you the common
controllers as attributes, so they read like any other event handler:

``` haskell
data Event = Clicked Double Double | KeyPressed Word32

clickable :: Widget Event
clickable =
  widget
    Label
      [ #label := "Click me"
      , onClickPressed (\_nPress x y -> Clicked x y)
      , onKeyPressed (\keyval _keycode _modifiers -> (True, KeyPressed keyval))
      ]
```

These are the ones this module names:

- Keys: `onKeyPressed` and `onKeyReleased`
- Clicks: `onClickPressed` and `onClickReleased`
- Pointer: `onMotion`, `onPointerEnter`, and `onPointerLeave`
- Focus: `onFocusEnter` and `onFocusLeave`
- Scrolling: `onScrolled`
- Dragging: `onDragBegin`, `onDragUpdate`, and `onDragEnd`
- Long presses: `onLongPressed`

The handler types follow the same rules as the ones above. A controller
signal that returns a `Bool`, such as `key-pressed`, takes a pure
handler returning a tuple of that `Bool` and the event.

For a controller this module does not name, and for handlers that need
the widget, use `onController` and `onControllerM`. They take an action
that makes the controller, one of its signals, and the handler:

``` haskell
widget Label
  [ onControllerM Gtk.eventControllerKeyNew #keyPressed
      (\keyval _keycode _modifiers _widget -> do
          name <- Gdk.keyvalName keyval
          pure (True, KeyNamed name))
  ]
```

A controller is added to the widget when the widget is subscribed to,
and removed when that subscription is cancelled, which is the same life
any other event handler here has. The library finds the controller again
by its name when it removes it, so a name you set on the controller
yourself does not survive.
