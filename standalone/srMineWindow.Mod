MODULE srMineWindow;
(* Native canvas backend for MiniA2's `ob build --gui`, without the A2 desktop. *)
IMPORT Displays, Inputs, Plugins, Raster;

TYPE
	Window* = OBJECT
	VAR
		backImg*: Raster.Image;
		display: Displays.Display;
		keyboard, mouse: Events;
		buttons: SET;
		closed: BOOLEAN;

		PROCEDURE Open*(width, height: SIZE);
		VAR plugin: Plugins.Plugin;
		BEGIN
			plugin := Displays.registry.Get("");
			ASSERT(plugin # NIL, 100);
			display := plugin(Displays.Display);
			ASSERT((display.width >= width) & (display.height >= height), 101);
			NEW(backImg);
			Raster.Create(backImg, width, height, Raster.DisplayFormat(display.format));
			NEW(keyboard, SELF); NEW(mouse, SELF);
			Inputs.keyboard.Register(keyboard); Inputs.mouse.Register(mouse);
			current := SELF
		END Open;

		PROCEDURE Present*;
		BEGIN
			IF ~closed THEN
				display.Transfer(backImg.mem^, 0, backImg.bpr, 0, 0,
					backImg.width, backImg.height, Displays.set);
				display.Update
			END
		END Present;

		PROCEDURE KeyEvent*(ucs: SIZE; flags: SET; keysym: SIZE);
		END KeyEvent;

		PROCEDURE PointerDown*(x, y: SIZE; keys: SET);
		END PointerDown;

		PROCEDURE PointerMove*(x, y: SIZE; keys: SET);
		END PointerMove;

		PROCEDURE WheelMove*(dz: SIZE);
		END WheelMove;

		PROCEDURE FocusLost*;
		END FocusLost;

		PROCEDURE Close*;
		BEGIN
			closed := TRUE
		END Close;

	END Window;

	Events = OBJECT(Inputs.Sink)
	VAR window: Window;

		PROCEDURE & Init*(w: Window);
		BEGIN
			window := w
		END Init;

		PROCEDURE Handle*(VAR message: Inputs.Message);
		BEGIN
			IF message IS Inputs.KeyboardMsg THEN
				WITH message: Inputs.KeyboardMsg DO
					IF (message.keysym = Inputs.KsEscape) & ~(Inputs.Release IN message.flags) THEN
						window.Close
					ELSE
						window.KeyEvent(ORD(message.ch), message.flags, message.keysym)
					END
				END
			ELSIF message IS Inputs.AbsMouseMsg THEN
				WITH message: Inputs.AbsMouseMsg DO
					IF message.keys - window.buttons # {} THEN
						window.PointerDown(message.x, message.y, message.keys)
					END;
					window.PointerMove(message.x, message.y, message.keys);
					IF message.dz # 0 THEN window.WheelMove(message.dz) END;
					window.buttons := message.keys
				END
			END
		END Handle;

	END Events;

VAR current: Window;

PROCEDURE Unregister*;
BEGIN
	(* Called by the main command after the input callback returns. Inputs holds its
	   broadcaster lock during callbacks, so unregistering inside Close would deadlock. *)
	IF current # NIL THEN
		Inputs.keyboard.Unregister(current.keyboard); Inputs.mouse.Unregister(current.mouse);
		current := NIL
	END
END Unregister;

END srMineWindow.
