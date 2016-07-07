
{.deadCodeElim: on.}

from algorithm import sort
import basic2d,
  hashes,
  math,
  os,
  random,
  sdl2,
  sdl2.image,
  sdl2.ttf,
  sequtils,
  sets,
  streams,
  strutils,
  tables,
  times,
  threadpool


import maze

when defined(gyro):
  from gyro import newGyro, readVector

const maze_size = 64

type
  SDLException = object of Exception

  Input {.pure.} = enum none, left, right, run, brake, restart, quit, camera_player,
    camera_opponent_1, camera_opponent_2, camera_opponent_2, camera_opponent_3,
    camera_opponent_4

  Collision {.pure.} = enum x, y, corner

  CacheLine = object
    texture: TexturePtr
    w, h: cint

  TextCache = ref object
    text: string
    cache: array[2, CacheLine]

  Time = ref object
    begin, finish, best: int

  MapTiles = array[0..maze_size, array[0..maze_size, int]]
  Map = ref object
    texture: TexturePtr
    width, height: int
    tiles*: MapTiles

  IntPoint = object
    ## 2D point with int coords
    x, y: int

  Route = Table[IntPoint, IntPoint]

  RouterParams = tuple[map: Map, start, goal: IntPoint, chan: ptr Channel[Route]]

type
  Player = ref object
    texture: TexturePtr
    pos: Point2d
    vel: Vector2d
    pos_z: float
    vel_z: float
    oil_on_wheels: float
    direction: Vector2d
    time: Time
    old_pos: Point2d
    old_direction: Vector2d
    brakes_on: int
    route: Route
    router_is_running: bool
    router_starting_tile: IntPoint
    router_start_time: float
    score: int
    name: string
    max_velocity,  acceleration, drift_rate_run, drift_rate, brake_rate, rotation_speed, slowdown_front_rate, slowdown_side_rate, slowdown_on_grass: float
    skin_pos: tuple[x, y: cint]
    router_thread: Thread[RouterParams]
    router_channel: Channel[Route]

  ItemKind {.pure.} = enum exhaust, dust, braking, drifting

  Item = ref object
    source: Rect
    pos: Point2d
    start_pos: Point2d
    kind: ItemKind
    expiration_time: int

  AutoPilotControls = tuple[steering, gas, braking: float]

  Game = ref object
    inputs: array[Input, bool]
    renderer: RendererPtr
    font: FontPtr
    player: Player
    opponents: seq[Player]
    items_texture: TexturePtr
    map: Map
    camera: Vector2d
    camera_on_player_num: int
    items: seq[Item]
    checkpoints: tuple[locations: seq[IntPoint], next: int]


proc toIntPoint(p: Point2d): IntPoint =
  return IntPoint(x: p.x.round.int, y: p.y.round.int)

when defined(gyro):
  let input_gyro = newGyro()

const
  windowSize: Point = (1480.cint, 840.cint)
  #windowSize: Point = (3280.cint, 1420.cint)
  #windowSize: Point = (1580.cint, 1020.cint)

  tilesPerRow = 16
  tileSize: Point = (64.cint, 64.cint)

  playerSize = vector2d(64, 64)

  # tiles
  air = 0
  grass = 7
  track = 1
  oil = 69
  minicorner_br = 48
  minicorner_bl = 49
  minicorner_tl = 50
  minicorner_tr = 51
  checkpoint_green = 83
  checkpoint_red = 84
  bones_array = @[2, 3, 66, 67, 68]
  bones = {2, 3, 66, 67, 68}


  camera_chasing_speed = 0.2

  two_pi = 2 * math.Pi
  rad_to_deg = 360 / two_pi
  deg_to_rad = two_pi / 360

  # colors
  white = color(255, 255, 255, 255)

proc toVector(p: IntPoint): Vector2d =
  vector2d(float(p.x * tileSize.x), float(p.y * tileSize.y))

proc vectorToTile(v: Vector2d): IntPoint =
  IntPoint(x: v.x.int div tileSize.x, y: v.y.int div tileSize.y)

proc toTile(v: Point2d): IntPoint =
  IntPoint(x: v.x.int div tileSize.x, y: v.y.int div tileSize.y)

proc toVector(p: Point2d): Vector2d =
  result = vector2d(p.x, p.y)

proc norm(v: Vector2d): Vector2d =
  result = v
  discard result.tryNormalize()

proc orthonormal(v: Vector2d): Vector2d =
  if v.len > 0:
    result = vector2d(v.y, v.x)
    result.normalize()
  else:
    result = vector2d(0, 0)

template inc_mod(v: var float, increment, bound: float) =
  v.inc increment
  v = v mod bound

template draw_line(game: Game, osrc, odst: Vector2d, col=color(200, 200, 200, 0)) =
  game.renderer.setDrawColor(col.r, col.g, col.b)
  let
    src = osrc - game.camera
    dst = odst - game.camera
  game.renderer.drawLine(src.x.cint, src.y.cint, dst.x.cint, dst.y.cint)

template sdlFailIf(cond: typed, reason: string) =
  if cond: raise SDLException.newException(
    reason & ", SDL error: " & $getError())


proc hash(p: IntPoint): Hash

proc render_shadow(renderer: RendererPtr, player: Player, pos: Point2d) =
  #if player.pos_z == 0:
  #  return

  let x = pos.x.cint + player.pos_z.cint
  let y = pos.y.cint + player.pos_z.cint

  var source = rect(64, 0, 32, 32)
  var dest = rect(x-16, y-16, 32, 32)

  renderer.copyEx(player.texture, source,
    dest,
    angle = player.direction.angle * rad_to_deg + 90,
    center = nil,
  )


proc render_player(renderer: RendererPtr, player: Player, pos: Point2d) =
  let
    x = pos.x.cint
    y = pos.y.cint

  var
    source = rect(player.skin_pos.x, player.skin_pos.y, 32, 32)
    dest = rect(x-16, y-16, 32, 32)

  renderer.copyEx(player.texture, source,
    dest,
    angle = player.direction.angle * rad_to_deg + 90,
    center = nil,
    )

  if player.brakes_on > 0:
    source = rect(32, 0, 32, 32)
    dest = rect(x-16, y-16, 32, 32)
    renderer.copyEx(
      player.texture,
      source,
      dest,
      angle = player.direction.angle * rad_to_deg + 90,
      center = nil,
    )
    player.brakes_on.dec
    if player.brakes_on > 20:
      player.brakes_on = 20

proc render_items(renderer: RendererPtr, game: Game) =
  ## Render dust, braking and so on

  for item in game.items:
    let
      pos = item.pos - game.camera
      x = pos.x.cint
      y = pos.y.cint
    var
      dest = rect(x, y, 16, 16)

    case item.kind
    of ItemKind.dust:
      renderer.copyEx(
        game.items_texture,
        item.source,
        dest,
        angle = 0,
        center = nil,
        flip = SDL_FLIP_NONE,
      )
    of ItemKind.braking:
      let spos = item.start_pos - game.camera
      renderer.setDrawColor(130, 81, 0, 0)
      renderer.drawLine(spos.x.cint, spos.y.cint, x, y)
    of ItemKind.drifting:
      renderer.setDrawColor(140, 91, 0, 0)
      let spos = item.start_pos - game.camera
      renderer.drawLine(spos.x.cint, spos.y.cint, x, y)
    else:
      discard

proc current_target_checkpoint(game: Game): IntPoint =
  game.checkpoints.locations[game.checkpoints.next]

proc render_big_arrow(renderer: RendererPtr, game: Game) =
  ## Render big arrow
  const center = vector2d(float(windowSize.x div 2), float(windowSize.y div 2))
  const z = 48
  let dist = game.current_target_checkpoint().toVector() - game.camera - center
  if dist.len < 60:
    return

  let angle = two_pi/8 * int(dist.angle/two_pi * 8 - 0.5).float
  let p = center + polarVector2d(angle, 400)
  var n = dist.norm() * 5

  if n.x < -1: n.x = z
  elif n.x < 1: n.x = center.x
  else: n.x = float(windowSize.x) - z
  if n.y < -1: n.y = z
  elif n.y < 1: n.y = center.y
  else: n.y = float(windowSize.y) - z

  var source = rect(32, 0, 32, 32) # arrow
  var dest = rect(n.x.cint - 32, n.y.cint - 32, 64, 64)

  renderer.copyEx(
    game.items_texture,
    source,
    dest,
    angle = dist.angle * rad_to_deg,
    center = nil,
    flip = SDL_FLIP_NONE,
  )

const dust_duration = [1, 2, 3, 4] # number of frames

const wheel_angles = [
  math.Pi/5,
  math.Pi * (1-1/5),
  math.Pi * (1+1/5),
  math.Pi * (2-1/5),
]

proc wheelvec(dir: Vector2d, wheel_angle: float): Vector2d =
  ## Calculate wheel position
  result = dir
  result.rotate(wheel_angle)
  result.len = 7

proc update_items(game: Game, tick: int) =
  game.items.keepItIf(it.expiration_time > tick)
  for i in game.items:
    # change/expire dust
    if i.kind != ItemKind.dust:
      continue
    if i.expiration_time - tick < dust_duration[0]:
      i.source = rect(0, 48, 16, 16)
    elif i.expiration_time - tick < dust_duration[1]:
      i.source = rect(0, 32, 16, 16)
    elif i.expiration_time - tick < dust_duration[2]:
      i.source = rect(0, 16, 16, 16)

proc add_dust(game: Game, tick: int) =
  ## Add dust particle
  let pos = game.player.pos + vector2d(-8, -8)- game.player.direction * 12
  game.items.add Item(
    kind: ItemKind.dust,
    source: rect(0, 0, 16, 16),
    pos: pos,
    expiration_time: tick + dust_duration[3],
  )

proc add_skid(game: Game, player: Player, tick: int, kind = ItemKind.braking) =
  ## Add skids
  for wheel_angle in wheel_angles:
    game.items.add Item(
      kind: kind,
      start_pos: player.old_pos +
        wheelvec(player.old_direction, wheel_angle),
      pos: player.pos +
        wheelvec(player.direction, wheel_angle),
      expiration_time: tick + 300,
    )

proc render_map(renderer: RendererPtr, map: Map, camera: Vector2d) =
  var
    clip = rect(0, 0, tileSize.x, tileSize.y)
    dest = rect(0, 0, tileSize.x, tileSize.y)

  for x in 0..maze_size:
    for y in 0..maze_size:
      let
        t = map.tiles[x][y]

      clip.x = cint(t mod tilesPerRow) * tileSize.x
      clip.y = cint(t div tilesPerRow) * tileSize.y
      dest.x = x.cint * tileSize.x - camera.x.cint
      dest.y = y.cint * tileSize.y - camera.y.cint

      renderer.copy(map.texture, unsafeAddr clip, unsafeAddr dest)


proc newTextCache: TextCache =
  new result

proc renderText(renderer: RendererPtr, font: FontPtr, text: string,
                x, y, outline: cint, color: Color): CacheLine =
  font.setFontOutline(outline)
  let surface = font.renderUtf8Blended(text.cstring, color)
  sdlFailIf surface.isNil: "Could not render text surface"

  discard surface.setSurfaceAlphaMod(color.a)

  result.w = surface.w
  result.h = surface.h
  result.texture = renderer.createTextureFromSurface(surface)
  sdlFailIf result.texture.isNil: "Could not create texture from rendered text"

  surface.freeSurface()

proc renderText(game: Game, text: string, x, y: cint, color: Color,
                tc: TextCache) =
  let passes = [(color: color(0, 0, 0, 64), outline: 2.cint),
                (color: color, outline: 0.cint)]

  if text != tc.text:
    for i in 0..1:
      tc.cache[i].texture.destroy()
      tc.cache[i] = game.renderer.renderText(
        game.font, text, x, y, passes[i].outline, passes[i].color)
    tc.text = text

  for i in 0..1:
    var source = rect(0, 0, tc.cache[i].w, tc.cache[i].h)
    var dest = rect(x - passes[i].outline, y - passes[i].outline,
                    tc.cache[i].w, tc.cache[i].h)
    game.renderer.copyEx(tc.cache[i].texture, source, dest,
                         angle = 0.0, center = nil)

template renderTextCached(game: Game, text: string, x, y: cint, color: Color) =
  block:
    var tc {.global.} = newTextCache()
    game.renderText(text, x, y, color, tc)

proc generate_route(player: Player, game: Game)

proc restart_player(player: Player) =
  player.pos = point2d(185, 170)
  player.vel = vector2d(0, 0)
  player.direction = vector2d(0, 1)
  player.time.begin = -1
  player.time.finish = -1

proc newTime: Time =
  new result
  result.finish = -1
  result.best = -1

proc new_player(game:Game, texture: TexturePtr, name="player", skin_x=0, skin_y=0): Player =
  new result
  result.texture = texture
  result.time = newTime()
  result.brakes_on = 0
  result.score = 0
  result.name = name
  result.skin_pos = (skin_x.cint, skin_y.cint)
  result.router_is_running = false
  result.restart_player()

  result.max_velocity = 150
  result.acceleration = 0.2
  result.brake_rate = 1.07
  result.drift_rate_run = 30
  result.drift_rate = 60
  result.rotation_speed = 0.1
  result.slowdown_front_rate = 0.008
  result.slowdown_side_rate = 0.015
  result.slowdown_on_grass = 0.92
  result.pos_z = 0.0
  result.vel_z = 0.0
  result.oil_on_wheels = 0.0
  if name == "player":
    result.slowdown_on_grass += 0.06
  else:
    result.max_velocity += random(-5.0..5.0)
    result.acceleration += random(-0.02..0.02)
    #result.drift_rate += random(-10.0..10.0)
    result.drift_rate_run += random(-10.0..10.0)
  if skin_y > 32 * 4: # buggy FIXME
    result.slowdown_on_grass += 0.05
    result.acceleration -= 0.02
    result.max_velocity -= 10.0
    result.drift_rate_run = 40
    result.brake_rate = 1.17


type MazeS* = array[0..maze_size, array[0..maze_size, int]]

proc stretch_maze(game: Game): MazeS =
  for y in countup(0, result.len-1):
    for x in countup(0, result.len-1):
      result[y][x] = grass

  let
    maze = generateMaze()
    maze_width = maze.len
    maze_height = maze[0].len

  for x in countup(0, maze_size - 1):
    let mx = int(x.float / 4.1)
    for y in countup(0, maze_size - 1):
      let my = int(y.float / 4.1)
      if mx < maze_width and my < maze_height:
        result[x][y] =
          if maze[mx][my] == 0: 1 else: grass

  var checkpoint_cnt = 0
  while checkpoint_cnt < 6:
    let
      x = random(1..maze_size)
      y = random(1..maze_size)
    if @[result[x][y], result[x-1][y], result[x+1][y], result[x][y+1], result[x][y-1]] == @[1, 1, 1, 1, 1]:
      checkpoint_cnt.inc
      game.checkpoints.locations.add IntPoint(x:x, y:y)

  # borders
  for y in countup(0, result.len-1):
    result[y][0] = grass
    result[y][maze_size-1] = grass
    result[0][y] = grass
    result[maze_size-1][y] = grass

proc newRandomMap2(game:Game): Map =
  new result

  var maze = game.stretch_maze()

  for x in countup(0, maze_size - 1):
    for y in countup(0, maze_size - 1):
      if x == 0 or x == (maze_size - 1) or y == 0 or y == (maze_size - 1):
        result.tiles[x][y] = 0
      elif maze[x][y] in {checkpoint_red, checkpoint_green}:
        result.tiles[x][y] = maze[x][y]
      else:
        let
          cell = maze[x][y]
          up = maze[x-1][y]
          down = maze[x+1][y]
          left = maze[x][y-1]
          right = maze[x][y+1]
        if cell == grass:
          result.tiles[x][y] = grass
        else:
          var r = grass
          if up == grass:
            if left == grass: # u l
              if right == grass: # u l r
                if down == grass:
                  r = grass
                else:
                  r = grass
              else: # u l R
                if down == grass:
                  r = grass
                else:
                  r = 32
            else: # u L
              if right == grass: # u L r
                if down == grass:
                  r = grass
                else:
                  r = 35
              else: # u L R
                if down == grass:
                  r = grass
                else:
                  r = 19
          else: # U
            if left == grass: # U l
              if right == grass:
                if down == grass:
                  r = grass
                else:
                  r = 52
              else: # U l R
                if down == grass:
                  r = 33
                else:
                  r = 16
            else: # U L
              if right == grass:
                if down == grass:
                  r = 34
                else:
                  r = 18
              else: # U L R
                if down == grass:
                  r = 17
                else:
                  # Filled
                  if maze[x-1][y-1] == grass:
                    r = minicorner_br
                  elif maze[x+1][y-1] == grass:
                    r = minicorner_bl
                  elif maze[x+1][y+1] == grass:
                    r = minicorner_tl
                  elif maze[x-1][y+1] == grass:
                    r = minicorner_tr
                  else:
                    # Regular track
                    case random(100)
                    of 1:
                      r = bones_array.random
                    of 2:
                      r = oil
                    else:
                      r = track

          result.tiles[x][y] = r


  result.width = maze_size
  result.height = maze_size

proc print_maze(map: Map) =
  for x in 0..maze_size:
    stdout.write align($x, 3)
  echo ""
  echo ""
  for y in 0..maze_size:
    for x in 0..maze_size:
      let c = map.tiles[x][y]
      var t = ""
      case c
      of grass: t = "."
      of track: t = " "
      of bones: t = "b"
      of oil: t = "o"
      else: t = $c
      stdout.write align(t, 3)
    echo ""
  echo ""
  echo ""


type MazeQ = array[0..15, array[0..15, bool]]
type MazePath = seq[IntPoint]

proc shuffle[T](x: var seq[T]) =
  for i in countdown(x.high, 0):
    let j = random(i + 1)
    swap(x[i], x[j])


proc print(maze: MazeQ) =
  for x in 0..15:
    for y in 0..15:
      stdout.write if maze[y][x]: "▉" else: " "
    echo " "

proc print(maze: ref MazeQ, clear=false) =
  echo ""
  if clear:
    echo "\x1bc"

  for x in 0..15:
    for y in 0..15:
      stdout.write if maze[y][x]: "▉" else: " "
    stdout.write "-"
    echo " "

proc print(maze: ref MazeQ, start, stop: IntPoint) =
  echo ""
  for x in 0..15:
    for y in 0..15:
      stdout.write if x == start.x and y == start.y:
          "s"
        elif x == stop.x and y == stop.y:
          "g"
        elif maze[x][y]:
          "▉"
        else:
          " "
    stdout.write "-"
    echo " "


proc step(imaze: MazeQ, old, goal:IntPoint): (MazeQ, IntPoint) =

  var options = @[0, 1, 2, 3]
  var maze = imaze
  options.shuffle()
  for o in options:
    let p =
      case o
      of 0: IntPoint(x: old.x + 1, y: old.y)
      of 1: IntPoint(x: old.x - 1, y: old.y)
      of 2: IntPoint(x: old.x, y: old.y + 1)
      else: IntPoint(x: old.x, y: old.y - 1)

    if maze[p.x][p.y] == true:  # collision
      continue

    if p.x > 15 or p.y > 15 or p.x == 0 or p.y == 0:
      # out of map, try next option
      continue

    if p == goal: # goal reached
      maze[p.x][p.y] = true
      return (maze, p)

    let (new_maze, new_p) = step(maze, p, goal)
    if new_p == p: # failed
      continue

    return (new_maze, new_p) # success

  # all options failed
  echo "giving up at ", old
  return (maze, old)


proc step_var2(maze: ref MazeQ, old, goal:IntPoint): IntPoint =

  var options = @[0, 1, 2, 3]
  options.shuffle()
  for o in options:
    let p =
      case o
      of 0: IntPoint(x: old.x + 1, y: old.y)
      of 1: IntPoint(x: old.x - 1, y: old.y)
      of 2: IntPoint(x: old.x, y: old.y + 1)
      else: IntPoint(x: old.x, y: old.y - 1)

    if maze[p.x][p.y] == true:  # collision
      continue
    if maze[p.x+1][p.y] == true:  # collision
      continue
    if maze[p.x-1][p.y] == true:  # collision
      continue
    if maze[p.x][p.y+1] == true:  # collision
      continue


    if p.x > 15 or p.y > 15 or p.x == 0 or p.y == 0:
      # out of map, try next option
      continue

    if p == goal: # goal reached
      maze[p.x][p.y] = true
      return p

    maze[p.x][p.y] = true
    let new_p = step_var2(maze, p, goal)
    if new_p == p: # failed
      maze[p.x][p.y] = false
      #maze.print()
      continue

    return new_p # success

  # all options failed
  echo "giving up at ", old
  return old

proc polarIntPoint(angle, le: int): IntPoint =
  let ang = angle mod 360
  case ang
  of 0: IntPoint(x:le, y:0)
  of 90: IntPoint(x:0, y:le)
  of 180: IntPoint(x: -le, y:0)
  of 270: IntPoint(x:0, y: -le)
  else: IntPoint(x:0, y:0)

proc `+`(a, b: IntPoint): IntPoint =
  IntPoint(x:a.x+b.x, y:a.y+b.y)


proc step_var(maze: ref MazeQ, old, goal:IntPoint, old_angle=0): IntPoint =
  ## Try stepping from "old" to a new position
  ## old_angle is the angle between "old" and the previous cell

  var options = @[90, 180, 270]
  options.shuffle()
  for a in options:
    let new_angle = a + old_angle
    let p = old + polarIntPoint(new_angle, 1)

    if maze[p.x][p.y] == true:  # collision
      continue

    if p == goal: # goal reached
      maze[p.x][p.y] = true
      return p

    const half = 7
    # p should be in the same quadrant as the old point
    if p.x div half != old.x div half:
      continue
    if p.y div half != old.y div half:
      continue

    if p.x > 15 or p.y > 15 or p.x == 0 or p.y == 0:
      # out of map, try next option
      continue

    # look for future collisions
    let area = @[
      polarIntPoint(new_angle, 1),
      polarIntPoint(new_angle + 90, 1),
      polarIntPoint(new_angle + 270, 1),
    ]
    for delta in area:
      let n = p + delta
      if maze[n.x][n.y]:
        continue

    if p.x > 15 or p.y > 15 or p.x == 0 or p.y == 0:
      # out of map, try next option
      continue

    maze[p.x][p.y] = true
    let new_p = step_var(maze, p, goal, old_angle=new_angle)
    if new_p == p: # failed
      maze[p.x][p.y] = false
      continue

    return new_p # success

  # all options failed
  #echo "giving up at ", old
  #maze.print()
  return old


proc generate_circuit(): MazeQ =
  let
    center = IntPoint(x:7, y:7)
    p1 = @[1.5, 2.0].random
    cos_omega = @[0.5, 1.0, 2.0, 3.0].random
    sin_omega = @[0.5, 1.0, 2.0, 3.0].random

  var angle = 0.0
  while angle <= 360.0:
    let
      a = angle * deg_to_rad
      r = cos(a * 4 + cos_omega) * p1 + 5 + sin(a * sin_omega)
      x = r * cos(a) + 7
      y = r * sin(a) + 7
    result[x.int][y.int] = true
    angle += 0.1

  #result.print()

proc stretch(game: Game, maze: MazeQ): MazeS =
  for y in countup(0, result.len-1):
    for x in countup(0, result.len-1):
      result[y][x] = grass

  let
    maze_width = maze.len
    maze_height = maze[0].len

  for x in countup(0, maze_size - 1):
    let mx = int(x.float / 4.1)
    for y in countup(0, maze_size - 1):
      let my = int(y.float / 4.1)
      if mx < maze_width and my < maze_height:
        result[x][y] =
          if maze[mx][my]: track else: grass

  var checkpoint_cnt = 0
  while checkpoint_cnt < 6:
    let
      x = random(1..maze_size)
      y = random(1..maze_size)
    if @[result[x][y], result[x-1][y], result[x+1][y], result[x][y+1], result[x][y-1]] == @[1, 1, 1, 1, 1]:
      checkpoint_cnt.inc
      game.checkpoints.locations.add IntPoint(x:x, y:y)

  # borders
  for y in countup(0, result.len-1):
    result[y][0] = grass
    result[y][maze_size-1] = grass
    result[0][y] = grass
    result[maze_size-1][y] = grass


#system.quit()
#
#let mz2  = new MazeQ
#let start = IntPoint(x:2, y:6)
#var prev = start
#for next in @[IntPoint(x:7, y:2), IntPoint(x:10, y:7), IntPoint(x:3, y:7), start]:
#  echo "HEADING from ", prev, "to ", next
#  discard step_var(mz2, prev, next)
#  mz2.print(prev, next)
#  prev = next
#
#
##for w in win:
##  echo w.x, ",", w.y
#
#mz2.print()
#echo "done"
#system.quit()


proc step(path: MazePath, goal:IntPoint): MazePath =

  let old = path[path.high]
  var options = @[0, 1, 2, 3]
  options.shuffle()
  for o in options:
    let p =
      case o
      of 0: IntPoint(x: old.x + 1, y: old.y)
      of 1: IntPoint(x: old.x - 1, y: old.y)
      of 2: IntPoint(x: old.x, y: old.y + 1)
      else: IntPoint(x: old.x, y: old.y - 1)

    if p == goal: # goal reached
      return path & p

    if p in path:
      continue

    if p.x > 15 or p.y > 15 or p.x == 0 or p.y == 0:
      # out of map, try next option
      continue

    let new_path = step(path & p, goal)
    if new_path.len == 0:
      continue  # failed

    return new_path

  # all options failed
  return @[]



proc new_random_map(game:Game): Map =
  new result
  #let maze = game.stretch_maze()
  let maze = game.stretch(generate_circuit())

  for x in countup(0, maze_size - 1):
    for y in countup(0, maze_size - 1):
      if x == 0 or x == (maze_size - 1) or y == 0 or y == (maze_size - 1):
        result.tiles[x][y] = 0
      elif maze[x][y] in {checkpoint_red, checkpoint_green}:
        result.tiles[x][y] = maze[x][y]
      else:
        let
          cell = maze[x][y]
          up = maze[x-1][y]
          down = maze[x+1][y]
          left = maze[x][y-1]
          right = maze[x][y+1]
        if cell == grass:
          result.tiles[x][y] = grass
        else:
          var r = grass
          if up == grass:
            if left == grass: # u l
              if right == grass: # u l r
                if down == grass:
                  r = grass
                else:
                  r = grass
              else: # u l R
                if down == grass:
                  r = grass
                else:
                  r = 32
            else: # u L
              if right == grass: # u L r
                if down == grass:
                  r = grass
                else:
                  r = 35
              else: # u L R
                if down == grass:
                  r = grass
                else:
                  r = 19
          else: # U
            if left == grass: # U l
              if right == grass:
                if down == grass:
                  r = grass
                else:
                  r = 52
              else: # U l R
                if down == grass:
                  r = 33
                else:
                  r = 16
            else: # U L
              if right == grass:
                if down == grass:
                  r = 34
                else:
                  r = 18
              else: # U L R
                if down == grass:
                  r = 17
                else:
                  # Filled
                  if maze[x-1][y-1] == grass:
                    r = minicorner_br
                  elif maze[x+1][y-1] == grass:
                    r = minicorner_bl
                  elif maze[x+1][y+1] == grass:
                    r = minicorner_tl
                  elif maze[x-1][y+1] == grass:
                    r = minicorner_tr
                  else:
                    # Regular track
                    case random(100)
                    of 1:
                      r = bones_array.random
                    of 2:
                      r = oil
                    else:
                      r = track

          result.tiles[x][y] = r
  result.width = maze_size
  result.height = maze_size
  #result.print_maze

proc cost_between(tiles: MapTiles, start, goal: IntPoint): int =
  let t = tiles[goal.x][goal.y]
  case t:
  of air: 90
  of grass: 25
  of track: 1
  else: 2


proc print_cost(map: Map) =
  for x in 0..maze_size:
    stdout.write align($x, 3)
  echo ""
  echo ""
  for y in 0..maze_size:
    for x in 0..maze_size:
      let goal = IntPoint(x:x, y:y)
      stdout.write align($cost_between(map.tiles, goal, goal), 3)
    echo ""
  echo ""
  echo ""


const dataDir = "data"

when defined(embedData):
  template readRW(filename: string): ptr RWops =
    const file = staticRead(dataDir / filename)
    rwFromConstMem(file.cstring, file.len)

  template readStream(filename: string): Stream =
    const file = staticRead(dataDir / filename)
    newStringStream(file)
else:
  let fullDataDir = getAppDir() / dataDir

  template readRW(filename: string): ptr RWops =
    var rw = rwFromFile(cstring(fullDataDir / filename), "r")
    sdlFailIf rw.isNil: "Cannot create RWops from file"
    rw

  template readStream(filename: string): Stream =
    var stream = newFileStream(fullDataDir / filename)
    if stream.isNil: raise ValueError.newException(
      "Cannot open file stream:" & fullDataDir / filename)
    stream

proc generate_routes(game: Game, now=false)

proc newGame(renderer: RendererPtr): Game =
  new result
  result.renderer = renderer
  result.checkpoints = (@[], 0)
  result.camera_on_player_num = 0
  result.items = @[]

  result.font = openFontRW(
    readRW("DejaVuSans.ttf"), freesrc = 1, 28)
  sdlFailIf result.font.isNil: "Failed to load font"

  result.map = result.newRandomMap()

  result.player = new_player(result, renderer.loadTexture_RW(
    readRW("cars.png"), freesrc = 1))

  result.opponents = @[]
  var skins = to_seq(0..7)
  skins.shuffle()
  for i in 0..2:
    let p = new_player(
      result,
      renderer.loadTexture_RW(readRW("cars.png"), freesrc = 1),
      skin_y=(32 * skins[i] + 32),
      name="$#" % $(i + 1),
    )
    result.opponents.add(p)

  result.generate_routes()
  for cnt, p in result.player & result.opponents:
    p.pos.x += (26 * cnt.float)

  result.items_texture = renderer.loadTexture_RW(readRW("items.png"), freesrc=1)
  result.map.texture = renderer.loadTexture_RW(readRW("grass.png"), freesrc = 1)

proc toInput(key: Scancode): Input =
  case key
  of SDL_SCANCODE_LEFT: Input.left
  of SDL_SCANCODE_RIGHT: Input.right
  of SDL_SCANCODE_UP: Input.run
  of SDL_SCANCODE_DOWN: Input.brake
  of SDL_SCANCODE_R: Input.restart
  of SDL_SCANCODE_ESCAPE: Input.quit
  of SDL_SCANCODE_1: Input.camera_player
  of SDL_SCANCODE_2: Input.camera_opponent_1
  of SDL_SCANCODE_3: Input.camera_opponent_2
  of SDL_SCANCODE_4: Input.camera_opponent_3
  of SDL_SCANCODE_5: Input.camera_opponent_4
  else: Input.none

proc handleInput(game: Game) =
  var event = defaultEvent
  while pollEvent(event):
    case event.kind
    of QuitEvent:
      game.inputs[Input.quit] = true
    of KeyDown:
      game.inputs[event.key.keysym.scancode.toInput] = true
    of KeyUp:
      game.inputs[event.key.keysym.scancode.toInput] = false
    else:
      discard

proc formatTime(ticks: int): string =
  let mins = (ticks div 50) div 60
  let secs = (ticks div 50) mod 60
  #interp"${mins:02}:${secs:02}"
  "$#:$#" % [$mins, $secs]

proc formatTimeExact(ticks: int): string =
  let cents = (ticks mod 50) * 2
  #interp"${formatTime(ticks)}:${cents:02}"
  "$#:$#" % [$ticks, $cents]

proc render_arrow(game: Game, start, dir: Vector2d,  col: Color) =
  let tip = start + dir * 8
  game.draw_line(
    start,
    tip,
    col=col,
  )
  game.draw_line(
    tip,
    tip + (dir.orthonormal() - dir) * 3,
    col=col,
  )
  game.draw_line(
    tip,
    tip + (- dir.orthonormal() - dir) * 3,
    col=col,
  )

proc render_route(game: Game, p: Player) =
  const half = vector2d(32, 32)
  for cell, next in p.route:
    var dir = next.toVector - cell.toVector
    discard dir.tryNormalize
    let start = cell.toVector + half
    game.render_arrow(start, dir, color(60, 60, 60, 9))

proc render_scores(renderer: RendererPtr, game:Game) =
  for pnum, p in game.player & game.opponents:
    let
      x = cint(pnum * 64 + 90)
      y = 8.cint
    game.renderTextCached($p.score, x, y, white)
    var source = rect(p.skin_pos.x, p.skin_pos.y, 32, 32)
    var dest = rect(x + 13.cint, y, 32, 32)
    let angle = if p.router_is_running: 40.0 else: 0.0
    renderer.copyEx(p.texture, source, dest, angle=angle, center = nil)


proc render(game: Game, tick: int) =

  # game.renderer.setDrawColor(110, 132, 174) # background
  # game.renderer.setDrawColor(140, 219, 38) # background
  game.renderer.setDrawColor(89, 140, 24) # background
  # Draw over all drawings of the last frame with the default color
  game.renderer.clear()
  # Actual drawing here
  game.renderer.render_map(game.map, game.camera)
  game.renderer.render_items(game)
  game.renderer.render_big_arrow(game)
  game.renderer.render_shadow(game.player, game.player.pos - game.camera)
  game.renderer.render_player(game.player, game.player.pos - game.camera)
  game.renderer.render_scores(game)
  for op in game.opponents:
    game.renderer.render_player(op, op.pos - game.camera)
  #game.render_route(game.opponents[0])

  let time = game.player.time
  if time.begin >= 0:
    game.renderTextCached(formatTime(tick - time.begin), 50, 100, white)
  elif time.finish >= 0:
    game.renderTextCached("Finished in: " & formatTimeExact(time.finish),
      50, 100, white)
  if time.best >= 0:
    game.renderTextCached("Best time: " & formatTimeExact(time.best),
      50, 150, white)

  # Show the result on screen
  game.renderer.present()


proc getTile(map: Map, x, y: int): int =
  let
    nx = clamp(x div tileSize.x, 0, map.width - 1)
    ny = clamp(y div tileSize.y, 0, map.height - 1)

  map.tiles[nx][ny]

proc getTile(map: Map, pos: Point2d): int =
  map.getTile(pos.x.round.int, pos.y.round.int)

proc setTile(map: Map, p: IntPoint , v: uint8) =
  map.tiles[p.x][p.y] = v.int

proc isSolid(map: Map, x, y: int): bool =
  map.getTile(x, y) notin {air}

proc isSolid(map: Map, point: Point2d): bool =
  map.isSolid(point.x.round.int, point.y.round.int)

proc is_on_ground(map: Map, p: Point2d): bool =
  map.getTile(p.x.round.int, p.y.round.int) notin {air}

proc is_on_air(map: Map, p: Point2d): bool =
  map.getTile(p.x.round.int, p.y.round.int) in {air}

proc is_on_grass(map: Map, p: Point2d): bool =
  map.getTile(p.x.round.int, p.y.round.int) in {grass}

proc onGround(map: Map, pos: Point2d, size: Vector2d): bool =
  let size = size * 0.5
  result =
    map.isSolid(point2d(pos.x - size.x, pos.y + size.y + 1)) or
    map.isSolid(point2d(pos.x + size.x, pos.y + size.y + 1))

proc move_box(map: Map, p:Player,
             size: Vector2d): set[Collision] {.discardable.} =
  let distance = p.vel.len
  let maximum = distance.int

  if distance < 0:
    return

  let fraction = 1.0 / float(maximum + 1)

  for i in 0 .. maximum:
    var newPos = p.pos + p.vel * fraction
    if map.is_on_air(newPos):
      p.vel.len = p.vel.len * 0.2
    elif p.pos_z > 0:
      # player is mid-air
      discard
    elif map.is_on_grass(newPos):
      p.vel.len = p.vel.len * p.slowdown_on_grass

    p.pos = newPos

proc print_route(game:Game, route: Route)

proc spawn_router(game:Game, p:Player)

proc autopilot(player:Player, game:Game): AutoPilotControls =
  ## decide where to go

  # collect thread output
  if player.router_is_running:
    if player.router_channel.peek() > 0:
      player.router_is_running = false
      let new_route = player.router_channel.recv()
      let routing_time = int((epochTime() - player.router_start_time) * 1000)
      if player.pos.toTile() in new_route:
        when defined(debug): echo player.name, " accepts route after $#ms" % $routing_time
        player.route = new_route
      else:
        when defined(debug): echo player.name, " discards route after $#ms" % $routing_time

    else:
      if epochTime() - player.router_start_time > 5:
        echo player.name, " timed out - RESET"
        player.restart_player()
        game.spawn_router(player)

  # even if the router is running for some reason the current route might be viable

  if player.pos.toTile() notin player.route:
    # we got lost or the next checkpoint changed: brake hard and reroute
    if not player.router_is_running:
      if player.vel.len > 10:
        when defined(debug):
          echo player.name, " no point in rerouting  - speed is ", player.vel.len.int
      else:
        when defined(debug):
          echo player.name, " rerouting  - speed is ", player.vel.len.int
        game.spawn_router(player)

    # brake while lost
    return (0.0, 0.0, 1.0)

  let
    pos = player.pos.toTile()
    cp = game.current_target_checkpoint()
    route = player.route
  var
    gas = 1.0
    braking = 0.0

  var next = route[pos]
  #echo "pos ", player.pos.toTile(), " next ", next
  var intention = next.toVector + vector2d(32, 32) - player.pos.toVector
  discard intention.tryNormalize()

  # look ahead
  var new_intention = vector2d(1, 0)
  if player.vel.len > 2 and route.hasKey(next):
    next = route[next]
    new_intention = next.toVector + vector2d(32, 32) - player.pos.toVector
    intention += new_intention
    discard intention.tryNormalize()
    if game.map.tiles[next.x][next.y] == checkpoint_red and player.vel.len > 3:
      braking += 1.0

  if player.vel.len > 3 and route.hasKey(next):
    next = route[next]
    new_intention = next.toVector + vector2d(32, 32) - player.pos.toVector
    intention += new_intention
    if new_intention.angleTo(player.direction) > 0.3:
      # slow down
      braking += 0.2
      gas = 0.0
    discard intention.tryNormalize()

  if player.vel.len > 5 and route.hasKey(next):
    next = route[next]
    new_intention = next.toVector + vector2d(32, 32) - player.pos.toVector
    intention += new_intention
    if new_intention.angleTo(player.direction) > 0.4:
      # panic
      braking = 1.0
      gas = 0.0
    elif new_intention.angleTo(player.direction) > 0.3:
      # slow down
      braking += 0.2
      gas = 0.0
    discard intention.tryNormalize()

  let steering = player.direction.turnAngle(intention)

  return (steering, gas, min(braking, 1.0))



proc physics(game: Game, tick: int) =
  let ground = true #game.map.onGround(game.player.pos, playerSize)

  when defined(gyro):
    let gyro_vector = input_gyro.readVector()
    if gyro_vector.y > 300:
      let vel = game.player.vel
      if vel.len < max_velocity:
        game.player.vel += (game.player.direction * acceleration)
        game.add_dust(tick)
      game.player.vel.rotate(vel.turnAngle(game.player.direction) / drift_rate_run)
      if game.player.vel.len < 3:
        game.add_skid(game.player, tick)

    elif gyro_vector.y < -300:
      let vel = game.player.vel
      game.player.vel.len = (vel.len / brake_rate)
      if game.player.vel.len > 3:
        game.add_skid(game.player, tick)

  for op in game.opponents:
    let ap = op.autopilot(game)
    let rs = min(op.rotation_speed, ap.steering /  10)
    op.direction.rotate(rs)
    let vel = op.vel

    if ap.braking > 0:
      op.vel -= vel * ap.braking * 0.1
      op.brakes_on.inc 10
    if ap.gas > 0:
      if vel.len < op.max_velocity:
        op.vel += (op.direction * op.acceleration * ap.gas)
        game.add_dust(tick)
      op.vel.rotate(vel.turnAngle(op.direction) / op.drift_rate_run)
      if op.vel.len < 3:
        game.add_skid(op, tick)

    # add drift marks
    if op.vel.len > 1 and
        op.vel.angleTo(op.direction) > 0.3:
      game.add_skid(op, tick, ItemKind.drifting)

    if vel.len > 0:
      let
        nvel = vel / vel.len
        slowdown_rate = dot(nvel, op.direction).abs * op.slowdown_front_rate +
          cross(nvel, op.direction).abs * op.slowdown_side_rate
      op.vel -= (vel * slowdown_rate)

    op.old_pos = op.pos
    op.old_direction = op.direction

    game.map.moveBox(op, playerSize)


  let p = game.player
  if p.pos_z == 0 and p.oil_on_wheels == 0:
    # on ground and without oil on the wheels
    let vel = game.player.vel
    if game.inputs[Input.run]:
      if vel.len < p.max_velocity:
        game.player.vel += (game.player.direction * p.acceleration)
        game.add_dust(tick)
      game.player.vel.rotate(vel.turnAngle(game.player.direction) / p.drift_rate_run)
      if game.player.vel.len < 3:
        game.add_skid(game.player, tick)

    else:
      game.player.vel.rotate(vel.turnAngle(game.player.direction) / p.drift_rate)

    if game.inputs[Input.right]:
      let rs = min(p.rotation_speed, p.rotation_speed * game.player.vel.len / 3)
      game.player.direction.rotate(rs)

    if game.inputs[Input.left]:
      let rs = min(p.rotation_speed, p.rotation_speed * game.player.vel.len / 3)
      game.player.direction.rotate(-rs)

    if game.inputs[Input.brake]:
      game.player.vel.len = (vel.len / p.brake_rate)
      if game.player.vel.len > 3:
        game.add_skid(game.player, tick)
      game.player.brakes_on.inc 10


    # add drift marks
    if game.player.vel.len > 1 and
        game.player.vel.angleTo(game.player.direction) > 0.3:
      game.add_skid(game.player, tick, ItemKind.drifting)

    if vel.len > 0:
      let
        nvel = vel / vel.len
        slowdown_rate = dot(nvel, game.player.direction).abs * p.slowdown_front_rate +
          cross(nvel, game.player.direction).abs * p.slowdown_side_rate
      game.player.vel -= (vel * slowdown_rate)

    game.player.old_pos = game.player.pos
    game.player.old_direction = game.player.direction

  elif p.pos_z > 0:
    # mid-air
    p.vel_z -= 0.1  # gravity
    p.pos_z += p.vel_z
    if p.pos_z <= 0:
      # just landed: update old position / direction to prevent glitches in the
      # skids
      p.pos_z = 0
      p.vel_z = 0
      p.old_pos = p.pos
      p.old_direction = p.direction

  else:
    # oil on wheels
    p.oil_on_wheels -= 0.1
    game.add_skid(game.player, tick, ItemKind.drifting)
    if p.oil_on_wheels <= 0:
      p.oil_on_wheels = 0

  case game.map.getTile(p.pos)
  of oil:
    p.oil_on_wheels = 1.5

  of bones:
    if p.pos_z == 0: # jump
      p.vel_z = p.vel.len / 10.0
      p.pos_z = 0.1

  of {checkpoint_green, checkpoint_red}:
    if p.pos_z == 0: # jump
      p.vel_z = p.vel.len / 6.0
      p.pos_z = 0.1

  else:
    discard

  game.map.moveBox(game.player, playerSize)

iterator triangolar_product(s: seq[Player]): (Player, Player) =
  for a_cnt, a in s:
    for b_cnt, b in s:
      if a_cnt != b_cnt:
        yield (a, b)

proc collisions(game: Game, tick: int) =
  ## Collisions
  for a in game.player & game.opponents:
    for b in game.player & game.opponents:
      if a == b:
        continue
      let dist = a.pos - b.pos
      if dist.len > 23:
        continue
      a.vel += (b.vel.norm * dist.norm) * b.vel * 0.5


proc moveCamera(game: Game) =
  if game.inputs[Input.camera_player]:
    game.camera_on_player_num = 0
  elif game.inputs[Input.camera_opponent_1]:
    game.camera_on_player_num = 1
  elif game.inputs[Input.camera_opponent_2]:
    game.camera_on_player_num = 2
  elif game.inputs[Input.camera_opponent_3]:
    game.camera_on_player_num = 3
  elif game.inputs[Input.camera_opponent_4]:
    game.camera_on_player_num = 4

  const center = point2d(float(windowSize.x div 2), float(windowSize.y div 2))
  let
    players = game.player & game.opponents
    target = players[min(players.high, game.camera_on_player_num)]
    dist = target.pos - game.camera - center
  game.camera += (dist * camera_chasing_speed)

var last_checkpoint = 0.uint8


proc set_checkpoint_colors(game: Game) =
  for loc in game.checkpoints.locations:
    game.map.setTile(loc, checkpoint_green.uint8)

  let loc = game.current_target_checkpoint()
  game.map.setTile(loc, checkpoint_red.uint8)


type WM = Table[IntPoint, int]
proc heuristic_cost_estimate(start, goal: IntPoint): int
proc pop_lowest_score(frontier: var Table[IntPoint, int]): IntPoint
proc get_or_inf(t: Table[IntPoint, int], k: IntPoint): int

iterator iter_neighbors(map: Map, c: IntPoint): IntPoint =
  for p in [IntPoint(x:c.x+1, y:c.y), IntPoint(x:c.x, y:c.y-1), IntPoint(x:c.x-1, y:c.y), IntPoint(x:c.x, y:c.y+1)]:
    if p.x >= 0 and p.y >= 0 and p.x < maze_size and p.y < maze_size:
      yield p

proc route_a_star_threaded(rp: RouterParams) {.thread gcsafe.} =
  let
    map = rp.map
    start = rp.start
    goal = rp.goal

  var
    closedSet = initSet[IntPoint](4)
    came_from: Route = initTable[IntPoint, IntPoint]()
    gScore: WM = initTable[IntPoint, int]()
    fScore: WM = {start:heuristic_cost_estimate(start, goal)}.toTable
    frontier: WM = {start: fScore[start]}.toTable  # openSet, with fScore as values
  gScore[start] = 0

  while frontier.len > 0:
    let current = frontier.pop_lowest_score()

    if current == goal:
      rp.chan[].send(came_from)
      return

    closedSet.incl current
    for neighbor in map.iter_neighbors(current):
      if neighbor in closedSet:
        continue
      # The distance from start to a neighbor
      let tentative_gScore = gScore.get_or_inf(current) + cost_between(map.tiles, current, neighbor)
      if neighbor in frontier and tentative_gScore >= gScore.get_or_inf(neighbor):
        # not an improvement
        continue

      # This path is the best so far
      came_from[neighbor] = current
      gScore[neighbor] = tentative_gScore
      fScore[neighbor] = gScore[neighbor] + heuristic_cost_estimate(neighbor, goal)
      frontier[neighbor] = fScore[neighbor]


proc spawn_router(game:Game, p:Player) =
  let goal = game.current_target_checkpoint()
  p.route = initTable[IntPoint, IntPoint]()
  p.router_is_running = true
  p.router_channel.open()
  p.router_start_time = epochTime()
  p.router_starting_tile = p.pos.toTile()
  let rp: RouterParams = (game.map, goal, p.router_starting_tile, addr p.router_channel)
  createThread(p.router_thread, route_a_star_threaded, rp)

proc generate_routes(game: Game, now=false) =

  for op in game.opponents:
    op.generate_route(game)

proc logic(game: Game, tick: int) =
  template time: expr = game.player.time
  for p in game.player & game.opponents:
    if game.map.getTile(p.pos) == checkpoint_red:
      # reached designated checkpoint!
      p.score.inc
      #game.checkpoints.next.inc
      #game.checkpoints.next = game.checkpoints.next mod game.checkpoints.locations.len
      var new_cp = random(0..game.checkpoints.locations.len)
      while new_cp == game.checkpoints.next:
        new_cp = random(0..game.checkpoints.locations.len)
      game.checkpoints.next = new_cp

      game.set_checkpoint_colors()

      # simply flush the route, the autopilot will take care of starting a
      # new routing thread if needed
      p.route = initTable[IntPoint, IntPoint]()

      if time.begin == -1:
        time.begin = tick
        return

      time.finish = tick - time.begin
      time.begin = tick
      if time.best < 0 or time.finish < time.best:
        time.best = time.finish

      return




proc hash(p: IntPoint): Hash =
  return p.x + p.y * 1024

proc cell_cost(map: Map, p: IntPoint): int =
  let t = map.tiles[p.x][p.y]
  case t:
  #of 0: 10
  #of 7: 5
  of 1: 30
  else: 0

type InsortItem = tuple[v: int, k: IntPoint]

proc insort(s: var seq[InsortItem], p: IntPoint, val: int) =
  let i:InsortItem = (val, p)
  s.add i

  s.sort do (a, b: InsortItem) -> int:
    result = cmp(a.v, b.v)


proc print_route(game:Game, route: Route) =
  echo ""
  for y in 0..maze_size:
    for x in 0..maze_size:
      let p = IntPoint(x:x, y:y)
      var symbol = $game.map.tiles[x][y]
      if route.hasKey(p):
        let d = route[p]
        symbol =
          if d.x == p.x + 1: "\u2192"
          elif d.x == p.x - 1: "\u2190"
          elif d.y == p.y + 1: "\u2193"
          elif d.y == p.y - 1: "\u2191"
          else: "\u2222"
        symbol = align(symbol, 5)

      stdout.write align(symbol, 3)


      discard
    echo ""
  echo ""


proc route_a_star(map: Map, start, goal: IntPoint): Route

proc generate_route(player: Player, game: Game) =
  let goal = game.current_target_checkpoint()
  #player.route = route_a_star(game.map, player.pos.toTile(), goal)
  player.route = route_a_star(game.map, goal, player.pos.toTile())

const infinity = 9999999  # not exactly infinity

proc pop_lowest_score(frontier: var Table[IntPoint, int]): IntPoint =
  # current = pop the lowest fScore from frontier
  var min_v = infinity
  var best_c: IntPoint
  for c, v in frontier:
    if v < min_v:
      min_v = v
      best_c = c

  del(frontier, best_c)
  return best_c

import sets

proc heuristic_cost_estimate(start, goal: IntPoint): int =
  return abs(start.x - goal.x) + abs(start.y - goal.y)


proc get_or_inf(t: Table[IntPoint, int], k: IntPoint): int =
  if t.hasKey(k):
    t[k]
  else:
    infinity

proc route_a_star(map: Map, start, goal: IntPoint): Route =
  var
    closedSet = initSet[IntPoint](4)
    came_from: Route = initTable[IntPoint, IntPoint]()
    gScore: WM = {start: 0}.toTable
    fScore: WM = {start:heuristic_cost_estimate(start, goal)}.toTable
    frontier: WM = {start: fScore[start]}.toTable  # openSet, with fScore as values

  while frontier.len > 0:
    let current = frontier.pop_lowest_score()

    if current == goal:
      return came_from

    closedSet.incl current
    for neighbor in map.iter_neighbors(current):
      if neighbor in closedSet:
        continue
      # The distance from start to a neighbor
      let tentative_gScore = gScore.get_or_inf(current) + cost_between(map.tiles, current, neighbor)
      if neighbor in frontier and tentative_gScore >= gScore.get_or_inf(neighbor):
        # not an improvement
        continue

      # This path is the best so far
      came_from[neighbor] = current
      gScore[neighbor] = tentative_gScore
      fScore[neighbor] = gScore[neighbor] + heuristic_cost_estimate(neighbor, goal)
      frontier[neighbor] = fScore[neighbor]



proc main =
  sdlFailIf(not sdl2.init(INIT_VIDEO or INIT_TIMER or INIT_EVENTS)):
    "SDL2 initialization failed"

  # defer blocks get called at the end of the procedure, even if an
  # exception has been thrown
  defer: sdl2.quit()

  sdlFailIf(not setHint("SDL_RENDER_SCALE_QUALITY", "2")):
    "Linear texture filtering could not be enabled"

  const imgFlags: cint = IMG_INIT_PNG
  sdlFailIf(image.init(imgFlags) != imgFlags):
    "SDL2 Image initialization failed"
  defer: image.quit()

  sdlFailIf(ttfInit() == SdlError):
    "SDL2 TTF initialization failed"
  defer: ttfQuit()

  let window = createWindow(title = "Our own 2D platformer",
    x = SDL_WINDOWPOS_CENTERED, y = SDL_WINDOWPOS_CENTERED,
    w = windowSize.x, h = windowSize.y, flags = SDL_WINDOW_SHOWN)
  sdlFailIf window.isNil: "Window could not be created"
  defer: window.destroy()

  let renderer = window.createRenderer(index = -1,
    flags = Renderer_Accelerated or Renderer_PresentVsync)
  sdlFailIf renderer.isNil: "Renderer could not be created"
  defer: renderer.destroy()

  showCursor(false)

  var
    game = newGame(renderer)
    startTime = epochTime()
    lastTick = 0

  game.set_checkpoint_colors()
  # Game loop, draws each frame
  while not game.inputs[Input.quit]:
    game.handleInput()

    let newTick = int((epochTime() - startTime) * 50)
    for tick in lastTick+1 .. newTick:
      game.collisions(tick)
      game.physics(tick)
      game.moveCamera()
      game.logic(tick)
      game.update_items(tick)
    lastTick = newTick

    game.render(lastTick)

if isMainModule:
  main()
