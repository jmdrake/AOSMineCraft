MODULE srMine;	(* A small Minecraft-style block world for the sr voxel raytracer *)
IMPORT srBase, Math, Out := KernelLog;

(*
	The world is one N x N x N grid of blocks filling the unit cube that srRender flies through.
	Every grid cell holds NIL (air) or a reference to one shared Block object, so all grass
	is the same GRASS object, all stone the same STONE object, and so on.

	Axis convention: +z is DOWN (this matches srBase.gravity, which adds to the camera's z speed).
	A block at height h above the bottom of the world has z index N-1-h.
*)

CONST
	N* = 64;	(* world size in blocks *)
	SEALEVEL = 20;	(* height of the water surface *)
	REACH = 12;	(* how far away (in blocks) you can break or place *)
	FOGDIST = 48;	(* distance (in blocks) at which fog has covered about 2/3 of a block *)
	EDGE = 0.04;	(* width of the dark outline drawn around each block face *)
	BIG = 1.0E30;
	NPAL = 9;	(* number of placeable block types *)

TYPE
	SREAL = srBase.SREAL;
	Ray = srBase.Ray;
	Voxel = srBase.Voxel;
	PT = srBase.PT;
	COLOR = srBase.COLOR;

	(* An opaque block. Lighting is fixed per face, like Minecraft: tops brightest, bottoms darkest. *)
	Block* = OBJECT(Voxel)
	VAR
		name*: ARRAY 16 OF CHAR;
		top*, side*: COLOR;

	PROCEDURE & init*(n: ARRAY OF CHAR; t, s: COLOR);
	BEGIN
		COPY(n, name);
		top := t; side := s;
		passable := FALSE;
	END init;

	PROCEDURE Shade(VAR ray: Ray);
	VAR
		c: COLOR;
		light, u, v: SREAL;
		ui, vi, h: SIGNED32;
	BEGIN
		CASE ray.face OF
			3: c := top; light := 1	(* ray was moving +z (down), so it hit the top face *)
			| 6: c := side; light := 0.5	(* bottom face *)
			| 1, 4: c := side; light := 0.8
			| 2, 5: c := side; light := 0.65
		ELSE
			c := top; light := 1	(* face 0: the ray started inside this block *)
		END;
		(* u,v = position of the hit point on the face, each in [0,1] *)
		CASE ray.face OF
			1, 4: u := ray.lxyz.y; v := ray.lxyz.z
			| 2, 5: u := ray.lxyz.x; v := ray.lxyz.z
		ELSE
			u := ray.lxyz.x; v := ray.lxyz.y
		END;
		IF (u < EDGE) OR (u > 1 - EDGE) OR (v < EDGE) OR (v > 1 - EDGE) THEN light := light * 0.75 END;
		(* 8x8 "pixel" texture: vary brightness a little per texel *)
		ui := ENTIER(u * 8); vi := ENTIER(v * 8);
		h := hash(ray.i * 8 + ui, ray.j * 8 + vi, ray.k * 8 + ray.face);
		light := light * (0.92 + (h MOD 17) / 100);
		ray.r := ray.r + c.red * light * ray.ra;
		ray.g := ray.g + c.green * light * ray.ga;
		ray.b := ray.b + c.blue * light * ray.ba;
		ray.ra := 0; ray.ga := 0; ray.ba := 0;
		ray.a := 0;
	END Shade;

	END Block;

	(* A see-through block: tints the ray and lets it continue. *)
	Water* = OBJECT(Block)

	PROCEDURE Shade(VAR ray: Ray);
	VAR k: SREAL;
	BEGIN
		IF ray.face = 3 THEN k := 0.45 ELSE k := 0.3 END;	(* the surface is a bit more opaque *)
		ray.r := ray.r + top.red * k * ray.ra;
		ray.g := ray.g + top.green * k * ray.ga;
		ray.b := ray.b + top.blue * k * ray.ba;
		ray.ra := ray.ra * (1 - k);
		ray.ga := ray.ga * (1 - k);
		ray.ba := ray.ba * (1 - k);
		ray.a := (ray.ra + ray.ga + ray.ba) / 3;
	END Shade;

	END Water;

	(* The whole world. srRender calls Shade once per pixel, from many threads at once. *)
	World* = OBJECT(Voxel)
	VAR
		blox*: ARRAY N, N, N OF Voxel;

	PROCEDURE & init*;
	BEGIN
		passable := FALSE;
		complex := TRUE;
	END init;

	PROCEDURE get*(i, j, k: SIGNED32): Voxel;
	BEGIN
		IF (i < 0) OR (i >= N) OR (j < 0) OR (j >= N) OR (k < 0) OR (k >= N) THEN RETURN NIL END;
		RETURN blox[i, j, k]
	END get;

	PROCEDURE set*(i, j, k: SIGNED32; v: Voxel);
	BEGIN
		IF (i >= 0) & (i < N) & (j >= 0) & (j < N) & (k >= 0) & (k < N) THEN blox[i, j, k] := v END
	END set;

	(* Walk the ray through the grid one cell at a time (Amanatides & Woo).
		ray.lxyz is the camera position in [0,1]; positions below are in block units. *)
	PROCEDURE Shade(VAR ray: Ray);
	VAR
		p, d: PT;
		i, j, k, si, sj, sk: SIGNED32;
		tx, ty, tz, dtx, dty, dtz, t, tlast: SREAL;
		face: SIGNED16;
		v: Voxel;
		sky: COLOR;
		out: BOOLEAN;
	BEGIN
		d := ray.dxyz;
		p.x := ray.lxyz.x * N; p.y := ray.lxyz.y * N; p.z := ray.lxyz.z * N;
		i := cell(p.x); j := cell(p.y); k := cell(p.z);
		axis(p.x, d.x, i, si, tx, dtx);
		axis(p.y, d.y, j, sj, ty, dty);
		axis(p.z, d.z, k, sk, tz, dtz);
		skycolor(d, sky);
		t := 0; tlast := 0; face := 0; out := FALSE;
		REPEAT
			v := blox[i, j, k];
			IF v # NIL THEN
				fog(ray, sky, t - tlast); tlast := t;
				ray.face := face;
				ray.lxyz.x := srBase.clamp(p.x + d.x * t - i);
				ray.lxyz.y := srBase.clamp(p.y + d.y * t - j);
				ray.lxyz.z := srBase.clamp(p.z + d.z * t - k);
				ray.i := SHORT(i); ray.j := SHORT(j); ray.k := SHORT(k);
				v.Shade(ray);
			END;
			IF ray.a >= 0.1 THEN
				IF (tx < ty) & (tx < tz) THEN
					t := tx; tx := tx + dtx; INC(i, si);
					IF si > 0 THEN face := 1 ELSE face := 4 END
				ELSIF ty < tz THEN
					t := ty; ty := ty + dty; INC(j, sj);
					IF sj > 0 THEN face := 2 ELSE face := 5 END
				ELSE
					t := tz; tz := tz + dtz; INC(k, sk);
					IF sk > 0 THEN face := 3 ELSE face := 6 END
				END;
				out := (i < 0) OR (i >= N) OR (j < 0) OR (j >= N) OR (k < 0) OR (k >= N)
			END
		UNTIL out OR (ray.a < 0.1);
		IF out THEN	(* the ray left the world: whatever light is left comes from the sky *)
			ray.r := ray.r + sky.red * ray.ra;
			ray.g := ray.g + sky.green * ray.ga;
			ray.b := ray.b + sky.blue * ray.ba;
			ray.ra := 0; ray.ga := 0; ray.ba := 0; ray.a := 0
		END
	END Shade;

	(* Find the first solid block along the ray, within REACH.
		hi,hj,hk = that block; pi,pj,pk = the cell just before it (where a new block would go). *)
	PROCEDURE pick(VAR ray: Ray; VAR hi, hj, hk, pi, pj, pk: SIGNED32; VAR found: BOOLEAN);
	VAR
		p, d: PT;
		i, j, k, si, sj, sk: SIGNED32;
		tx, ty, tz, dtx, dty, dtz, t: SREAL;
		v: Voxel;
		out: BOOLEAN;
	BEGIN
		d := ray.dxyz;
		p.x := ray.lxyz.x * N; p.y := ray.lxyz.y * N; p.z := ray.lxyz.z * N;
		i := cell(p.x); j := cell(p.y); k := cell(p.z);
		axis(p.x, d.x, i, si, tx, dtx);
		axis(p.y, d.y, j, sj, ty, dty);
		axis(p.z, d.z, k, sk, tz, dtz);
		t := 0; found := FALSE; out := FALSE;
		REPEAT
			pi := i; pj := j; pk := k;
			IF (tx < ty) & (tx < tz) THEN t := tx; tx := tx + dtx; INC(i, si)
			ELSIF ty < tz THEN t := ty; ty := ty + dty; INC(j, sj)
			ELSE t := tz; tz := tz + dtz; INC(k, sk)
			END;
			out := (i < 0) OR (i >= N) OR (j < 0) OR (j >= N) OR (k < 0) OR (k >= N);
			IF ~out THEN
				v := blox[i, j, k];
				IF (v # NIL) & ~v.passable THEN found := TRUE; hi := i; hj := j; hk := k END
			END
		UNTIL found OR out OR (t > REACH)
	END pick;

	(* srRender calls this for the 'd' key: break the block under the cursor *)
	PROCEDURE deathray(VAR ray: Ray);
	VAR hi, hj, hk, pi, pj, pk: SIGNED32; found: BOOLEAN;
	BEGIN
		pick(ray, hi, hj, hk, pi, pj, pk, found);
		IF found & (blox[hi, hj, hk] # BEDROCK) THEN blox[hi, hj, hk] := NIL END
	END deathray;

	(* srRender calls this for the 'e' key: place the selected block against the face under the cursor *)
	PROCEDURE mutateray(ray: Ray);
	VAR hi, hj, hk, pi, pj, pk, ci, cj, ck: SIGNED32; found: BOOLEAN;
	BEGIN
		pick(ray, hi, hj, hk, pi, pj, pk, found);
		ci := cell(ray.lxyz.x * N); cj := cell(ray.lxyz.y * N); ck := cell(ray.lxyz.z * N);
		IF found & ~((pi = ci) & (pj = cj) & (pk = ck)) THEN	(* never build inside the camera *)
			set(pi, pj, pk, palette[selected])
		END
	END mutateray;

	PROCEDURE probe(x, y, z: SREAL): Voxel;
	BEGIN
		RETURN blox[cell(x * N), cell(y * N), cell(z * N)]
	END probe;

	PROCEDURE solid(x, y, z: SREAL): BOOLEAN;
	VAR v: Voxel;
	BEGIN
		v := probe(x, y, z);
		RETURN (v # NIL) & ~v.passable
	END solid;

	(* The camera bumped into something: cancel only the blocked parts of its velocity,
		so it slides along walls and comes to rest on the ground. *)
	PROCEDURE probeShade(VAR ray: Ray; VAR dx, dy, dz: SREAL);
	VAR x, y, z: SREAL;
	BEGIN
		x := ray.xyz.x; y := ray.xyz.y; z := ray.xyz.z;
		IF solid(x + dx, y, z) THEN dx := 0 END;
		IF solid(x + dx, y + dy, z) THEN dy := 0 END;
		IF solid(x + dx, y + dy, z + dz) THEN dz := 0 END
	END probeShade;

	END World;

VAR
	world*: World;
	GRASS, DIRT, STONE, SAND, WOOD, LEAVES, PLANKS, BRICK, BEDROCK: Block;
	WATER: Water;
	palette: ARRAY NPAL OF Block;
	selected: SIGNED32;
	spawnx*, spawny*, spawnz*: SREAL;	(* srRender.hopcamera puts the camera here *)

PROCEDURE hash(a, b, c: SIGNED32): SIGNED32;
VAR h: SIGNED32;
BEGIN
	h := (a * 7919 + b * 6271 + c * 3037) MOD 4093;
	RETURN (h * h + a) MOD 4093
END hash;

(* grid cell containing coordinate x (in block units), clamped to the world *)
PROCEDURE cell(x: SREAL): SIGNED32;
VAR c: SIGNED32;
BEGIN
	c := ENTIER(x);
	IF c < 0 THEN c := 0 ELSIF c >= N THEN c := N - 1 END;
	RETURN c
END cell;

(* DDA setup for one axis: step direction, distance to the first cell boundary, distance between boundaries *)
PROCEDURE axis(pos, dir: SREAL; c: SIGNED32; VAR s: SIGNED32; VAR tmax, tdelta: SREAL);
BEGIN
	IF dir > 0 THEN s := 1; tdelta := 1 / dir; tmax := (c + 1 - pos) / dir
	ELSIF dir < 0 THEN s := -1; tdelta := -1 / dir; tmax := (c - pos) / dir
	ELSE s := 0; tdelta := BIG; tmax := BIG
	END
END axis;

PROCEDURE skycolor(d: PT; VAR c: COLOR);
VAR up: SREAL;
BEGIN
	up := -d.z;	(* -z is up *)
	IF up < 0 THEN up := 0 END;
	c.red := 0.75 - 0.4 * up;
	c.green := 0.85 - 0.3 * up;
	c.blue := 1.0 - 0.05 * up
END skycolor;

(* blend in sky-coloured fog for a stretch of air dist blocks long *)
PROCEDURE fog(VAR ray: Ray; sky: COLOR; dist: SREAL);
VAR f: SREAL;
BEGIN
	f := 1 - Math.exp(-dist / FOGDIST);
	ray.r := ray.r + sky.red * f * ray.ra;
	ray.g := ray.g + sky.green * f * ray.ga;
	ray.b := ray.b + sky.blue * f * ray.ba;
	ray.ra := ray.ra * (1 - f);
	ray.ga := ray.ga * (1 - f);
	ray.ba := ray.ba * (1 - f);
	ray.a := (ray.ra + ray.ga + ray.ba) / 3
END fog;

PROCEDURE rgb(r, g, b: SREAL): COLOR;
VAR c: COLOR;
BEGIN
	c.red := r; c.green := g; c.blue := b; c.alpha := 1;
	RETURN c
END rgb;

(* put a block at column x,y, height h above the bottom *)
PROCEDURE put(x, y, h: SIGNED32; v: Voxel);
BEGIN
	world.set(x, y, N - 1 - h, v)
END put;

PROCEDURE at(x, y, h: SIGNED32): Voxel;
BEGIN
	RETURN world.get(x, y, N - 1 - h)
END at;

(* terrain height above the bottom at column x,y: a few overlapping sine waves *)
PROCEDURE height(x, y: SIGNED32): SIGNED32;
VAR h: SREAL;
BEGIN
	h := 22 + 7 * Math.sin(x / 9) * Math.cos(y / 11) + 4 * Math.sin((x + 2 * y) / 17) + 2 * Math.cos((x - y) / 6);
	RETURN ENTIER(h)
END height;

PROCEDURE tree(x, y, h: SIGNED32);
VAR dx, dy, dz, r: SIGNED32;
BEGIN
	FOR dz := 0 TO 4 DO put(x, y, h + dz, WOOD) END;
	FOR dz := 3 TO 6 DO
		IF dz < 5 THEN r := 2 ELSE r := 1 END;
		FOR dx := -r TO r DO FOR dy := -r TO r DO
			IF ((ABS(dx) # r) OR (ABS(dy) # r) OR (r = 1)) & (at(x + dx, y + dy, h + dz) = NIL) THEN
				put(x + dx, y + dy, h + dz, LEAVES)
			END
		END END
	END
END tree;

PROCEDURE generate;
VAR x, y, z, h, n: SIGNED32;
BEGIN
	FOR x := 0 TO N - 1 DO
		FOR y := 0 TO N - 1 DO
			h := height(x, y);
			FOR z := 0 TO h DO
				IF z = 0 THEN put(x, y, z, BEDROCK)
				ELSIF z < h - 3 THEN put(x, y, z, STONE)
				ELSIF z < h THEN put(x, y, z, DIRT)
				ELSIF h <= SEALEVEL + 1 THEN put(x, y, z, SAND)
				ELSE put(x, y, z, GRASS)
				END
			END;
			FOR z := h + 1 TO SEALEVEL DO put(x, y, z, WATER) END
		END
	END;
	FOR n := 1 TO 30 DO
		x := 3 + srBase.rand.Dice(N - 6);
		y := 3 + srBase.rand.Dice(N - 6);
		h := height(x, y);
		IF h > SEALEVEL + 1 THEN tree(x, y, h + 1) END
	END;
	(* spawn in the middle, a few blocks above the ground *)
	h := height(N DIV 2, N DIV 2);
	IF h < SEALEVEL THEN h := SEALEVEL END;
	spawnx := (N DIV 2 + 0.5) / N;
	spawny := (N DIV 2 + 0.5) / N;
	spawnz := (N - 1 - (h + 4) + 0.5) / N
END generate;

(* key 'b' in srRender: choose the next block type to place *)
PROCEDURE nextblock*;
BEGIN
	selected := (selected + 1) MOD NPAL;
	Out.String("srMine: placing "); Out.String(palette[selected].name); Out.Ln
END nextblock;

(* srRender's camera-trail hooks; not used in this world *)
PROCEDURE cameratrail*(v: Voxel; a, b: PT);
END cameratrail;

PROCEDURE trailswitch*;
END trailswitch;

BEGIN
	NEW(GRASS, "grass", rgb(0.36, 0.70, 0.25), rgb(0.55, 0.42, 0.27));
	NEW(DIRT, "dirt", rgb(0.55, 0.40, 0.26), rgb(0.55, 0.40, 0.26));
	NEW(STONE, "stone", rgb(0.50, 0.50, 0.52), rgb(0.50, 0.50, 0.52));
	NEW(SAND, "sand", rgb(0.86, 0.80, 0.55), rgb(0.86, 0.80, 0.55));
	NEW(WOOD, "wood", rgb(0.65, 0.52, 0.32), rgb(0.40, 0.29, 0.17));
	NEW(LEAVES, "leaves", rgb(0.22, 0.52, 0.18), rgb(0.22, 0.52, 0.18));
	NEW(PLANKS, "planks", rgb(0.72, 0.56, 0.34), rgb(0.72, 0.56, 0.34));
	NEW(BRICK, "brick", rgb(0.62, 0.27, 0.22), rgb(0.62, 0.27, 0.22));
	NEW(BEDROCK, "bedrock", rgb(0.20, 0.20, 0.20), rgb(0.20, 0.20, 0.20));
	NEW(WATER, "water", rgb(0.15, 0.35, 0.75), rgb(0.15, 0.35, 0.75));
	WATER.passable := TRUE;
	palette[0] := GRASS; palette[1] := DIRT; palette[2] := STONE;
	palette[3] := PLANKS; palette[4] := BRICK; palette[5] := WOOD;
	palette[6] := LEAVES; palette[7] := SAND; palette[8] := WATER;
	selected := 3;
	NEW(world);
	generate;
	srBase.world := world
END srMine.

PC.Compile \s srMine.Mod srRender.Mod ~
SystemTools.Free srRender srMine ~
srRender.Open ~
