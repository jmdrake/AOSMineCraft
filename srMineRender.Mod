MODULE srMineRender;	(* first-person walking camera for the srMine block world *)
IMPORT Modules, Kernel, Inputs, WMWindowManager, Raster, Objects,
	Rectangles := WMRectangles, Out := KernelLog, Math, srBase, srMine, srRayEngine;

(*
	Controls
		W A S D	walk
		Space	jump (swim up in water, fly up in fly mode)
		C	fly down (fly mode)
		F	toggle walk / fly
		left-drag	look around
		right click or X	break the block under the crosshair
		middle click or E	place a block against the face under the crosshair
		B or mouse wheel	choose the block type to place (shown top right; name also in the Kernel Log)
		[ ]	zoom in / out
		P	toggle half-resolution tracing (faster)
		H	go back to the spawn point
		Q	quit

	Units: the player's position and speeds are in blocks. The renderer works in the unit
	cube, so positions are divided by srMine.N when the rays are built.
	+z is down, as in srMine.
*)

CONST
	W = srBase.LW; H = srBase.LH;	(* traced resolution: uses srBase.lrays / limage *)
	SCALE = 2;	(* each traced pixel is drawn SCALE x SCALE on screen *)
	CX = W DIV 2; CY = H DIV 2;	(* the crosshair ray *)
	LOOKSPEED = 0.005;	(* radians per pixel of mouse drag *)
	WALKSPEED = 4.3; FLYSPEED = 10;	(* blocks per second *)
	GRAVITY = 25;	(* blocks per second per second *)
	JUMPSPEED = 8;
	MAXFALL = 40;
	HALFWIDTH = 0.3;	(* the player is 0.6 blocks wide... *)
	HEAD = 0.2;	(* ...the top of the head is 0.2 above the eye... *)
	FEET = 1.5;	(* ...and the feet are 1.5 below it *)
	EPS = 0.001;
	(* Unix A2 only reports key RELEASES for Shift/Ctrl/Alt (see Unix.KbdMouse.Mod), so we can't see
		when W is let go. Instead, a key counts as held while presses keep arriving: X11 auto-repeat
		sends one after FIRSTHOLD-ish ms, then a steady stream. Lower FIRSTHOLD if you shorten the
		repeat delay with  xset r rate 250 30  *)
	FIRSTHOLD = 700;	(* ms a single press stays held: must cover the auto-repeat delay *)
	REPEATHOLD = 150;	(* ms between auto-repeat presses, plus slack *)
	KFWD = 0; KBACK = 1; KLEFT = 2; KRIGHT = 3; KJUMP = 4; KDOWN = 5; NKEYS = 6;

TYPE
	SREAL = srBase.SREAL;
	PT = srBase.PT;

	Window = OBJECT(WMWindowManager.DoubleBufferWindow)
	VAR
		lastx, lasty: SIZE;
		closed: BOOLEAN;

	PROCEDURE & New*;
	BEGIN
		Init(W * SCALE, H * SCALE, FALSE);
		manager := WMWindowManager.GetDefaultManager();
		manager.Add(100, 100, SELF, {WMWindowManager.FlagFrame, WMWindowManager.FlagClose});
	END New;

	PROCEDURE KeyEvent* (ucs : SIZE; flags : SET; keysym : SIZE);
	VAR ch: CHAR; down: BOOLEAN;
	BEGIN
		IF (ucs > 0) & (ucs < 128) THEN ch := CHR(ucs)
		ELSIF (keysym > 0) & (keysym < 128) THEN ch := CHR(keysym)	(* release events may only carry the keysym *)
		ELSE ch := 0X
		END;
		IF (ch >= "A") & (ch <= "Z") THEN ch := CHR(ORD(ch) + 32) END;
		down := ~(Inputs.Release IN flags);
		CASE ch OF
			"w": keyevent(KFWD, down)
			| "s": keyevent(KBACK, down)
			| "a": keyevent(KLEFT, down)
			| "d": keyevent(KRIGHT, down)
			| " ": keyevent(KJUMP, down); IF down THEN jumpreq := TRUE END
			| "c": keyevent(KDOWN, down)
		ELSE
			IF down THEN
				CASE ch OF
					"f": flying := ~flying; vz := 0;
						IF flying THEN Out.String("srMine: fly mode") ELSE Out.String("srMine: walk mode") END; Out.Ln
					| "b": srMine.nextblock
					| "e": PLACE := TRUE
					| "x": BREAK := TRUE
					| "h": home
					| "p": srRayEngine.fast := ~srRayEngine.fast
					| "[": tanhalf := tanhalf * 0.95
					| "]": tanhalf := tanhalf / 0.95
					| "q": Close
				ELSE
				END
			END
		END
	END KeyEvent;

	PROCEDURE PointerDown* (x, y : SIZE; keys : SET);
	BEGIN
		lastx := x; lasty := y;
		IF 2 IN keys THEN BREAK := TRUE END;
		IF 1 IN keys THEN PLACE := TRUE END
	END PointerDown;

	PROCEDURE PointerMove* (x, y : SIZE; keys : SET);
	BEGIN
		IF 0 IN keys THEN
			yaw := yaw + (x - lastx) * LOOKSPEED;
			pitch := pitch - (y - lasty) * LOOKSPEED;
			IF pitch > 1.55 THEN pitch := 1.55 ELSIF pitch < -1.55 THEN pitch := -1.55 END
		END;
		lastx := x; lasty := y
	END PointerMove;

	PROCEDURE WheelMove*(dz : SIZE);
	BEGIN
		IF dz > 0 THEN srMine.nextblock ELSIF dz < 0 THEN srMine.prevblock END
	END WheelMove;

	PROCEDURE FocusLost*;
	VAR k: SIGNED32;
	BEGIN	(* we won't see any more key presses, so let go of everything *)
		FOR k := 0 TO NKEYS - 1 DO keyevent(k, FALSE) END
	END FocusLost;

	PROCEDURE Close;
	BEGIN
		srBase.worldalive := FALSE;
		IF ~closed THEN closed := TRUE; Close^ END
	END Close;

	END Window;

	MainLoop = OBJECT
	VAR
		w: Window;
		t, last: SIGNED32;
		dt: SREAL;
	BEGIN {ACTIVE, PRIORITY(Objects.Normal)}
		w := window;
		last := Kernel.GetTicks();
		REPEAT
			t := Kernel.GetTicks();
			dt := (t - last) / 1000; last := t;
			IF dt > 0.1 THEN dt := 0.1 END;	(* don't jump through walls after a long frame *)
			physics(dt);
			initrays;
			IF BREAK THEN block.deathray(srBase.lrays[CX, CY]); BREAK := FALSE END;
			IF PLACE THEN place; PLACE := FALSE END;
			srRayEngine.lgo;
			IF srBase.worldalive THEN draw(w) END
		UNTIL ~srBase.worldalive
	END MainLoop;

VAR
	window: Window;
	main: MainLoop;
	block: srBase.Voxel;
	mode: Raster.Mode;
	px, py, pz: SREAL;	(* eye position, in blocks *)
	vx, vy, vz: SREAL;	(* velocity, in blocks per second *)
	yaw, pitch: SREAL;	(* radians; yaw 0 looks along +x, positive pitch looks up *)
	tanhalf: SREAL;	(* tan(half the horizontal field of view) *)
	onground, flying: BOOLEAN;
	lastpress: ARRAY NKEYS OF SIGNED32;	(* Kernel.GetTicks of each key's latest press *)
	repeating: ARRAY NKEYS OF BOOLEAN;	(* is that key auto-repeating? *)
	jumpreq: BOOLEAN;	(* space was pressed since the last frame *)
	key: SIGNED32;
	BREAK, PLACE: BOOLEAN;

(* ---------- keyboard ---------- *)

PROCEDURE keyevent(k: SIGNED32; down: BOOLEAN);
VAR t: SIGNED32;
BEGIN
	t := Kernel.GetTicks();
	IF down THEN
		repeating[k] := t - lastpress[k] < 2 * REPEATHOLD;
		lastpress[k] := t
	ELSE	(* a real release (other ports), or focus lost *)
		lastpress[k] := t - 100000; repeating[k] := FALSE
	END
END keyevent;

PROCEDURE held(k: SIGNED32): BOOLEAN;
VAR elapsed: SIGNED32;
BEGIN
	elapsed := Kernel.GetTicks() - lastpress[k];
	IF repeating[k] THEN RETURN elapsed < REPEATHOLD ELSE RETURN elapsed < FIRSTHOLD END
END held;

(* ---------- player movement ---------- *)

PROCEDURE solidAt(i, j, k: SIGNED32): BOOLEAN;
VAR v: srBase.Voxel;
BEGIN
	IF (i < 0) OR (i >= srMine.N) OR (j < 0) OR (j >= srMine.N) OR (k >= srMine.N) THEN RETURN TRUE END;	(* world edges and floor *)
	IF k < 0 THEN RETURN FALSE END;	(* open sky above the world *)
	v := srMine.world.get(i, j, k);
	RETURN (v # NIL) & ~v.passable
END solidAt;

(* would the player, with the eye at x,y,z, overlap a solid block? *)
PROCEDURE blocked(x, y, z: SREAL): BOOLEAN;
VAR i, j, k: SIGNED32;
BEGIN
	FOR i := ENTIER(x - HALFWIDTH) TO ENTIER(x + HALFWIDTH - EPS) DO
		FOR j := ENTIER(y - HALFWIDTH) TO ENTIER(y + HALFWIDTH - EPS) DO
			FOR k := ENTIER(z - HEAD) TO ENTIER(z + FEET - EPS) DO
				IF solidAt(i, j, k) THEN RETURN TRUE END
			END
		END
	END;
	RETURN FALSE
END blocked;

PROCEDURE inwater(): BOOLEAN;
VAR v: srBase.Voxel;
BEGIN
	v := srMine.world.get(ENTIER(px), ENTIER(py), ENTIER(pz + 1));	(* about waist height *)
	RETURN (v # NIL) & v.passable
END inwater;

PROCEDURE physics(dt: SREAL);
VAR
	fx, fy, mx, my, len, speed, m, step, nz, oz: SREAL;
	n, s: SIGNED32;
	water: BOOLEAN;
BEGIN
	(* which way do the keys say to walk? *)
	fx := Math.cos(yaw); fy := Math.sin(yaw);
	mx := 0; my := 0;
	IF held(KFWD) THEN mx := mx + fx; my := my + fy END;
	IF held(KBACK) THEN mx := mx - fx; my := my - fy END;
	IF held(KRIGHT) THEN mx := mx - fy; my := my + fx END;
	IF held(KLEFT) THEN mx := mx + fy; my := my - fx END;
	len := Math.sqrt(mx * mx + my * my);
	IF len > 0 THEN mx := mx / len; my := my / len END;

	water := inwater();
	IF flying THEN speed := FLYSPEED ELSIF water THEN speed := WALKSPEED / 2 ELSE speed := WALKSPEED END;
	vx := mx * speed; vy := my * speed;
	IF flying THEN
		vz := 0;
		IF held(KJUMP) THEN vz := -speed END;
		IF held(KDOWN) THEN vz := speed END
	ELSIF water THEN
		vz := vz + GRAVITY / 5 * dt;
		IF vz > 2 THEN vz := 2 END;
		IF held(KJUMP) THEN vz := -3 END
	ELSE
		vz := vz + GRAVITY * dt;
		IF vz > MAXFALL THEN vz := MAXFALL END;
		IF jumpreq & onground THEN vz := -JUMPSPEED END	(* holding space keeps jumping, via auto-repeat *)
	END;
	jumpreq := FALSE;

	(* move in small steps, one axis at a time, so we slide along walls and never skip through a block *)
	m := ABS(vx); IF ABS(vy) > m THEN m := ABS(vy) END; IF ABS(vz) > m THEN m := ABS(vz) END;
	n := ENTIER(m * dt / 0.25) + 1;
	step := dt / n;
	onground := FALSE;
	FOR s := 1 TO n DO
		IF ~blocked(px + vx * step, py, pz) THEN px := px + vx * step END;
		IF ~blocked(px, py + vy * step, pz) THEN py := py + vy * step END;
		nz := pz + vz * step;
		IF ~blocked(px, py, nz) THEN
			pz := nz
		ELSE
			oz := pz;
			IF vz > 0 THEN	(* landed: put the feet exactly on top of the block *)
				pz := ENTIER(nz + FEET) - FEET - EPS; onground := TRUE
			ELSE	(* bumped the head *)
				pz := ENTIER(nz - HEAD) + 1 + HEAD + EPS
			END;
			IF blocked(px, py, pz) THEN pz := oz END;
			vz := 0
		END
	END;
	IF pz < HEAD - 8 THEN pz := HEAD - 8 END	(* don't fly off into space *)
END physics;

PROCEDURE home;
BEGIN
	px := srMine.spawnx * srMine.N; py := srMine.spawny * srMine.N; pz := srMine.spawnz * srMine.N;
	vx := 0; vy := 0; vz := 0;
	yaw := 0; pitch := 0
END home;

(* ---------- camera ---------- *)

(* A pinhole camera: every ray goes through a point on a flat image plane one unit in front of the eye.
	f = forward, r = right, d = down (screen rows go down), all unit vectors. *)
PROCEDURE initrays;
VAR
	i, j: SIGNED32;
	f, r, d, cam: PT;
	sx, sy, cy, sy0, cp, sp: SREAL;
BEGIN
	cy := Math.cos(yaw); sy0 := Math.sin(yaw);
	cp := Math.cos(pitch); sp := Math.sin(pitch);
	f.x := cp * cy; f.y := cp * sy0; f.z := -sp;
	r.x := -sy0; r.y := cy; r.z := 0;
	d.x := sp * cy; d.y := sp * sy0; d.z := cp;	(* f x r *)
	cam.x := px / srMine.N; cam.y := py / srMine.N; cam.z := pz / srMine.N;
	FOR i := 0 TO W - 1 DO
		sx := (2 * (i + 0.5) / W - 1) * tanhalf;
		FOR j := 0 TO H - 1 DO
			sy := (2 * (j + 0.5) / H - 1) * tanhalf * H / W;
			srBase.lrays[i, j] := srBase.blankray;
			srBase.lrays[i, j].dxyz.x := f.x + sx * r.x + sy * d.x;
			srBase.lrays[i, j].dxyz.y := f.y + sx * r.y + sy * d.y;
			srBase.lrays[i, j].dxyz.z := f.z + sx * r.z + sy * d.z;
			srBase.normalizePT(srBase.lrays[i, j].dxyz);
			srBase.lrays[i, j].ddxyz.x := srBase.lrays[i, j].dxyz.x / 10000;
			srBase.lrays[i, j].ddxyz.y := srBase.lrays[i, j].dxyz.y / 10000;
			srBase.lrays[i, j].ddxyz.z := srBase.lrays[i, j].dxyz.z / 10000;
			srBase.lrays[i, j].xyz := cam;
			srBase.lrays[i, j].lxyz := cam
		END
	END
END initrays;

PROCEDURE place;
BEGIN
	block.mutateray(srBase.lrays[CX, CY]);
	IF srMine.placed & blocked(px, py, pz) THEN	(* it went where we are standing: take it back *)
		srMine.world.set(srMine.placedi, srMine.placedj, srMine.placedk, NIL)
	END
END place;

PROCEDURE draw(w: Window);
VAR
	i, j, step: SIGNED32;
	pixel: Raster.Pixel;
	c: srBase.COLOR;
BEGIN
	IF srRayEngine.fast THEN step := 2 ELSE step := 1 END;	(* fast mode only traces every other pixel *)
	i := 0;
	WHILE i < W DO
		j := 0;
		WHILE j < H DO
			c := srBase.limage[i, j];
			Raster.SetRGB(pixel, ENTIER(c.red * 255), ENTIER(c.green * 255), ENTIER(c.blue * 255));
			Raster.Fill(w.backImg, i * SCALE, j * SCALE, (i + step) * SCALE, (j + step) * SCALE, pixel, mode);
			INC(j, step)
		END;
		INC(i, step)
	END;
	(* crosshair *)
	Raster.SetRGB(pixel, 255, 255, 255);
	Raster.Fill(w.backImg, CX * SCALE - 8, CY * SCALE - 1, CX * SCALE + 8, CY * SCALE + 1, pixel, mode);
	Raster.Fill(w.backImg, CX * SCALE - 1, CY * SCALE - 8, CX * SCALE + 1, CY * SCALE + 8, pixel, mode);
	hud(w);
	w.Swap;
	w.Invalidate(Rectangles.MakeRect(0, 0, w.GetWidth(), w.GetHeight()))
END draw;

(* Draw the selected block as a small isometric cube in the top-right corner.
	For each pixel we work out which face of the cube it is on, and shade it like Block.Shade:
	top face full brightness, left side 0.8, right side 0.65. *)
PROCEDURE hud(w: Window);
CONST
	A = 22;	(* cube size in pixels (centre to top corner) *)
	T = 0.5774;	(* tan 30 degrees: slope of the cube's edges *)
	PAD = 10;
VAR
	b: srMine.Block;
	cx, cy, x, y: SIGNED32;
	dx, dy, adx, light: SREAL;
	c: srBase.COLOR;
	pixel: Raster.Pixel;
BEGIN
	b := srMine.current();
	cx := W * SCALE - PAD - A; cy := PAD + A;
	Raster.SetRGB(pixel, 40, 40, 40);	(* dark panel behind the cube *)
	Raster.Fill(w.backImg, cx - A - 6, cy - A - 6, cx + A + 6, cy + A + 6, pixel, mode);
	FOR y := cy - A TO cy + A DO
		FOR x := cx - A TO cx + A DO
			dx := x - cx; dy := y - cy; adx := ABS(dx);
			IF (adx <= 0.866 * A) & (dy >= -A + adx * T) & (dy <= A - adx * T) THEN	(* inside the hexagon outline *)
				IF dy < -adx * T THEN c := b.top; light := 1
				ELSIF dx < 0 THEN c := b.side; light := 0.8
				ELSE c := b.side; light := 0.65
				END;
				(* dark lines along the cube's edges *)
				IF (ABS(dy + adx * T) < 1) OR ((adx < 1) & (dy > 0)) OR
					(dy < -A + adx * T + 1.5) OR (dy > A - adx * T - 1.5) OR (adx > 0.866 * A - 1.5) THEN
					light := light * 0.5
				END;
				Raster.SetRGB(pixel, ENTIER(c.red * light * 255), ENTIER(c.green * light * 255), ENTIER(c.blue * light * 255));
				Raster.Put(w.backImg, x, y, pixel, mode)
			END
		END
	END
END hud;

(* ---------- commands ---------- *)

PROCEDURE Open*;
BEGIN
	IF (window # NIL) & srBase.worldalive THEN RETURN END;	(* already running *)
	block := srMine.world;
	srRayEngine.setBlock(block);
	srRayEngine.fast := FALSE;
	srBase.worldalive := TRUE;
	NEW(window);
	NEW(main)
END Open;

PROCEDURE Close*;
BEGIN
	IF window # NIL THEN window.Close; window := NIL END
END Close;

BEGIN
	Raster.InitMode(mode, Raster.srcCopy);
	tanhalf := 0.7;	(* about 70 degrees across *)
	FOR key := 0 TO NKEYS - 1 DO keyevent(key, FALSE) END;
	home;
	Modules.InstallTermHandler(Close)
END srMineRender.

PC.Compile \s srMine.Mod srMineRender.Mod ~
SystemTools.Free srMineRender srMine ~
srMineRender.Open ~
