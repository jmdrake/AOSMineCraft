MODULE srMineApp;
IMPORT Kernel, Out := KernelLog, srBase, srMineRender, srMineWindow;

PROCEDURE Do*;
VAR timer: Kernel.Timer;
BEGIN
	Out.String("AOSMineCraft: starting standalone game"); Out.Ln;
	srMineRender.Open;
	NEW(timer);
	WHILE srBase.worldalive DO timer.Sleep(20) END;
	srMineRender.Close;
	srMineWindow.Unregister
END Do;

END srMineApp.
