MODULE srMineWindow;
(* Window backend for the A2 desktop. Task builds use standalone/srMineWindow.Mod instead. *)
IMPORT WMWindowManager, WMRectangles;

TYPE
	Window* = OBJECT(WMWindowManager.DoubleBufferWindow)

		PROCEDURE Open*(width, height: SIZE);
		BEGIN
			Init(width, height, FALSE);
			manager := WMWindowManager.GetDefaultManager();
			manager.Add(100, 100, SELF, {WMWindowManager.FlagFrame, WMWindowManager.FlagClose})
		END Open;

		PROCEDURE Present*;
		BEGIN
			Swap;
			Invalidate(WMRectangles.MakeRect(0, 0, GetWidth(), GetHeight()))
		END Present;

	END Window;

END srMineWindow.
