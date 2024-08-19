extends Node2D


const UNIT := 1000.0 # "resolution" of the unit grid

@onready var viewport_rect:Rect2 = get_viewport_rect()
@onready var timers: Node = %Timers
@onready var camera:Camera2D = %Camera
@onready var canvas:Node2D = %Canvas
@onready var ui:Control = %UIContainer
@onready var start_points = %StartPoints
@onready var color_bkgd = %ColorBkgd
@onready var color_edge = %ColorEdge
@onready var color_vertex = %ColorVertex
@onready var color_search = %ColorSearch
@onready var color_3_pt = %Color3Pt
@onready var color_2_pt = %Color2Pt
@onready var color_1_pt = %Color1Pt
@onready var color_0_pt = %Color0Pt
@onready var slow_mo = %SlowMo
@onready var log_text:TextEdit = %LogText
@onready var play_button: Button = %PlayButton
@onready var recolor_button: Button = %RecolorButton
@onready var rand_color_button: Button = %RandColorButton
@onready var reset_button: Button = %ResetButton

enum Phase {ADD_K_VERTICES, ADD_EDGES, FIND_EDGE_INTERSECTIONS, TRIANGLE_SEARCH, DRAWING, REDRAWING, DONE, IDLE}
enum Layer {BACKGROUND, EDGES, VERTICES, TRIANGLES, SEARCH}
var phase:Phase
var playing:bool = false
var delta_accum:float = 0.0
var vertices:Array = []
var vertex_index:Dictionary = {}
var edges:Array = []
var iter:Choose2Iterator
var tri:CandidateIterator
var tried:Dictionary = {}
var coedges:Dictionary = {}
var triangle_counts:Array = [0, 0, 0, 0]
var triangles:Array = [[], [], [], []]
var coloring_parent:Node2D
var draw_k:int
var draw_v:int
var rand_color:bool = false


func info(s:String) -> void:
	log_text.insert_text_at_caret(s)


func infoln(s:String) -> void:
	info(s)
	log_text.insert_text_at_caret("\n")


# play/pause button
func _on_play_button_pressed():
	if playing:
		pause_timers()
		play_button.text = "Play"
		playing = false
	else:
		# restarting?
		if vertices.size() < 1:
			reset_canvas()
			phase = Phase.ADD_K_VERTICES
		unpause_timers()
		play_button.text = "Pause"
		playing = true


func _on_recolor_button_pressed() -> void:
	for node:Node2D in coloring_parent.get_children():
		node.queue_free()
	draw_k = 3
	draw_v = 0
	phase = Phase.REDRAWING
	playing = true


func _on_rand_color_pressed() -> void:
	rand_color = true
	_on_recolor_button_pressed()


func _on_reset_button_pressed() -> void:
	reset_canvas()
	vertices = []
	vertex_index = {}
	edges = []
	tried = {}
	coedges = {}
	triangle_counts = [0, 0, 0, 0]
	triangles = [[], [], [], []]
	play_button.disabled = false
	play_button.text = "Play"
	recolor_button.disabled = true
	rand_color_button.disabled = true
	playing = false


func _on_size_changed() -> void:
	# update the viewport_rect variable
	viewport_rect = get_viewport_rect()
	# center the camera
	camera.position = viewport_rect.size / 2
	# position the canvas
	canvas.position.y = viewport_rect.size.y / 2
	canvas.position.x = (2 * viewport_rect.size.x - viewport_rect.size.y) / 2
	# scale the canvas for normal cartesian plane from -2 to +2
	canvas.scale = 0.96 * Vector2(viewport_rect.size.y, -viewport_rect.size.y) / 2.0
	# extend the ui container to the viewport height
	ui.custom_minimum_size.y = viewport_rect.size.y


func _process(delta:float) -> void:
	if playing and not throttle(delta):
		match phase:
			Phase.ADD_K_VERTICES:
				if vertices.size() < start_points.value:
					info("k vertex: ")
					add_vertex(Vector2i(Vector2(0,UNIT).rotated(2.0 * PI * vertices.size() / start_points.value).round()))
				else:
					iter = Choose2Iterator.new(start_points.value)
					phase = Phase.ADD_EDGES
			Phase.ADD_EDGES:
				if iter.next():
					add_edge(iter.i, iter.j)
				else:
					iter = Choose2Iterator.new(edges.size())
					phase = Phase.FIND_EDGE_INTERSECTIONS
			Phase.FIND_EDGE_INTERSECTIONS:
				if iter.next():
					setup_find_next_intersection()
				else:
					tri = CandidateIterator.new(vertices, edges)
					phase = Phase.TRIANGLE_SEARCH
			Phase.TRIANGLE_SEARCH:
				if tri.next():
					var try := tri.candidate()
					# make sure all three points are different and we haven't tried them before
					if not (try.x == try.y or try.x == try.z or try.y == try.z or have_tried(try)):
						#print("          trying %s" % [try])
						show_search_try(try)
						infoln("possible triangle: %s" % [try])
						if shared_edge(Vector2i(try.y, try.z)):
							var k:int = 0
							for i in [try.x, try.y, try.z]:
								k += 1 if i < start_points.value else 0
							infoln("  triangle found (%s k points)" % [k])
							triangle_counts[k] += 1
							triangles[k].append(try)
					else:
						skip_next_throttle = true
				else:
					draw_k = 3
					draw_v = 0
					phase = Phase.DRAWING
			Phase.DRAWING, Phase.REDRAWING:
				if draw_v < triangles[draw_k].size():
					draw_triangle(triangles[draw_k][draw_v], draw_k)
					draw_v += 1
				else:
					if draw_k < 1:
						rand_color = false
						if phase == Phase.DRAWING:
							phase = Phase.DONE
						else:
							phase = Phase.IDLE
					else:
						draw_k -= 1
						draw_v = 0
			Phase.DONE:
				#print("timers children: %s" % [timers.get_child_count()])
				var total_triangles:int
				for n in triangle_counts:
					total_triangles += n
				infoln("triangle_counts found: %s %s" % [total_triangles, triangle_counts])
				playing = false
				play_button.text = "Play"
				play_button.disabled = true
				recolor_button.disabled = false
				rand_color_button.disabled = false
				infoln("done!")
				phase = Phase.IDLE


func _ready() -> void:
	# manual call to size_changed() for initial positioning of 2D nodes
	_on_size_changed()
	# connect a listener for viewport size change
	get_tree().get_root().connect("size_changed", _on_size_changed)


func add_edge(v1:int, v2:int) -> void:
	# add an entry for the new edge
	edges.append({})
	var e:Dictionary = edges.back()
	# store the edge endpoints as a vector containing the vertex indices
	e.ends = Vector2i(v1,v2)
	# dictionary for tracking incident vertices
	e.incident_vertices = {}
	e.incident_vertices[v1] = true
	e.incident_vertices[v2] = true
	# add this edge to the incident_edge dictionary of each vertex
	var idx := edges.size() - 1
	vertices[v1].incident_edges[idx] = true
	vertices[v2].incident_edges[idx] = true
	# draw the edge
	draw_edge(idx)
	# show a search edge
	show_search_edge(idx)
	# log info
	infoln("edge: [%s] %s" % [idx, e.ends])


# add a new vertex at point p to the puzzle
# optionally incident to edges e1 and e2
func add_vertex(p:Vector2i, e1:int = -1, e2:int = -1) -> void:
	# add an entry for the new vertex
	vertices.append({})
	var v:Dictionary = vertices.back()
	# store its position and canonical name
	v.position = p
	v.name = "%s" % [p]
	# dictionary for tracking incident edges
	v.incident_edges = {}
	# save any incident edges
	if e1 >= 0:
		v.incident_edges[e1] = true
	if e2 >= 0:
		v.incident_edges[e2] = true
	# add the edge to the index for looking up vertices by canonical name
	var idx := vertices.size() - 1
	vertex_index[v.name] = idx
	# create a vertex disc at the point location
	draw_vertex(idx)
	# show a search vertex
	show_search_vertex(idx)
	# log info
	infoln("[%s] %s" % [idx, p])


# create a filled circle sprite using a shader
const TRANSPARENT_PIXEL:CompressedTexture2D = preload("res://pixels/transparent.png")
const DISC_SHADER:Shader = preload("res://circle.gdshader")
func disc_2d(radius:float, color:Color, edge_softness:float = 0.0) -> Sprite2D:
	# create a sprite with any texture (we just use a single transparent pixel)
	var disc:Sprite2D = Sprite2D.new()
	disc.scale = Vector2(radius, radius)
	disc.texture = TRANSPARENT_PIXEL
	# add the disc shader
	disc.material = ShaderMaterial.new()
	disc.material.shader = DISC_SHADER
	disc.material.set_shader_parameter("size", 1.0)
	disc.material.set_shader_parameter("color", color)
	disc.material.set_shader_parameter("edge_softness", edge_softness)
	return disc


func draw_edge(n:int) -> void:
	var line:Line2D = Line2D.new()
	line.add_point(vertices[edges[n].ends.x].position / UNIT)
	line.add_point(vertices[edges[n].ends.y].position / UNIT)
	line.width = 0.005
	line.default_color = color_edge.color
	line.z_index = Layer.EDGES
	canvas.add_child(line)


func draw_vertex(n:int) -> void:
	var disc := disc_2d(0.02, color_vertex.color)
	disc.position = vertices[n].position / UNIT
	disc.z_index = Layer.VERTICES
	canvas.add_child(disc)


func draw_triangle(t:Vector3i, k:int) -> void:
	#print("draw %s %s" % [t, k])
	var triangle := Polygon2D.new()
	triangle.polygon = PackedVector2Array([vertices[t.x].position / UNIT, vertices[t.y].position / UNIT, vertices[t.z].position / UNIT])
	#print("  points %s" % [triangle.polygon])
	if rand_color:
		triangle.color = Color(randf(), randf(), randf(), randf())
	else:
		match k:
			0:
				triangle.color = color_0_pt.color
			1:
				triangle.color = color_1_pt.color
			2:
				triangle.color = color_2_pt.color
			3:
				triangle.color = color_3_pt.color
	triangle.z_index = Layer.TRIANGLES
	coloring_parent.add_child(triangle)


func show_search_vertex(n:int) -> void:
	var disc := disc_2d(0.02, color_search.color)
	disc.position = vertices[n].position / UNIT
	disc.z_index = Layer.SEARCH
	canvas.add_child(disc)
	var timer := Timer.new()
	timer.wait_time = 0.1
	timer.autostart = true
	timer.one_shot = true
	timer.connect("timeout", search_graphic_timeout.bind(disc, timer))
	timers.add_child(timer)


func show_search_edge(n:int) -> void:
	var line:Line2D = Line2D.new()
	line.add_point(vertices[edges[n].ends.x].position / UNIT)
	line.add_point(vertices[edges[n].ends.y].position / UNIT)
	line.width = 0.005
	line.default_color = color_search.color
	line.z_index = Layer.SEARCH
	canvas.add_child(line)
	var timer := Timer.new()
	timer.wait_time = 0.1
	timer.autostart = true
	timer.one_shot = true
	timer.connect("timeout", search_graphic_timeout.bind(line, timer))
	timers.add_child(timer)


func show_search_try(try:Vector3i) -> void:
	var line:Line2D = Line2D.new()
	line.add_point(vertices[try.x].position / UNIT)
	line.add_point(vertices[try.y].position / UNIT)
	line.add_point(vertices[try.z].position / UNIT)
	line.add_point(vertices[try.x].position / UNIT)
	line.width = 0.005
	line.default_color = color_search.color
	line.z_index = Layer.SEARCH
	canvas.add_child(line)
	var timer := Timer.new()
	timer.wait_time = 0.1
	timer.autostart = true
	timer.one_shot = true
	timer.connect("timeout", search_graphic_timeout.bind(line, timer))
	timers.add_child(timer)


func search_graphic_timeout(graphic_node:Node2D, timer:Timer) -> void:
	graphic_node.queue_free()
	timer.queue_free()


func pause_timers() -> void:
	for timer:Timer in timers.get_children():
		timer.paused = true


func unpause_timers() -> void:
	for timer:Timer in timers.get_children():
		timer.paused = false


# https://www.geeksforgeeks.org/check-if-two-given-line-segments-intersect/
func is_point_on_line_segment(a:Vector2, b:Vector2, p:Vector2) -> bool:
	if (p.x <= max(a.x, b.x) and p.x >= min(a.x, b.x) and p.y <= max(a.y, b.y) and p.y >= min(a.y, b.y)):
		return true
	return false


func shared_edge(duo:Vector2i) -> bool:
	# make sure duo is sorted
	duo = Vector2i(min(duo.x, duo.y), max(duo.x, duo.y))
	# give the duo a canonical name
	var duo_name := "%s" % [duo]
	# if we already checked this duo, return the cached result
	if coedges.has(duo_name):
		return coedges[duo_name]
	# assume no shared edge (then we will search for one)
	coedges[duo_name] = false
	# for all edges in duo.x, check to see if duo.y has the same edge
	for edge in vertices[duo.x].incident_edges.keys():
		if vertices[duo.y].incident_edges.has(edge):
			coedges[duo_name] = true
			return true
	return false


func have_tried(try:Vector3i) -> bool:
	var sorted_try := [try.x, try.y, try.z]
	sorted_try.sort()
	try = Vector3i(sorted_try[0], sorted_try[1], sorted_try[2])
	var name := "%s" % [try]
	if tried.has(name):
		return true
	else:
		tried[name] = true
		return false


# https://www.geeksforgeeks.org/program-for-point-of-intersection-of-two-lines/
func line_segments_intersection(a:Vector2, b:Vector2, c:Vector2, d:Vector2) -> Variant:
	# line ab as: a1x + b1y = c1
	var a1 := b.y - a.y
	var b1 := a.x - b.x
	var c1 := a1 * a.x + b1 * a.y
	# line cd as: a2x + b2y = c2
	var a2 := d.y - c.y
	var b2 := c.x - d.x
	var c2 := a2 * c.x + b2 * c.y
	# determinant
	var det := a1 * b2 - a2 * b1
	# det == 0 implies parallel lines
	if is_equal_approx(det, 0.0):
		#print("intersecting (%s,%s) [%s,%s] with [%s,%s]: PARALLEL" % [i, j, a, b, c, d])
		return null
	# p is the point of intersection
	var p := Vector2((b2 * c1 - b1 * c2) / det, (a1 * c2 - a2 * c1) / det)
	# rule out the intersection being an original endpoint
	if p.is_equal_approx(a) or p.is_equal_approx(b) or p.is_equal_approx(c) or p.is_equal_approx(d):
		#print("intersecting (%s,%s) [%s,%s] with [%s,%s]: ENDPOINT %s" % [i,j, a, b, c, d, p])
		return null
	# verify the intersection lies within both segments
	if not (is_point_on_line_segment(a, b, p) and is_point_on_line_segment(c,d, p)):
		#print("intersecting (%s,%s) [%s,%s] with [%s,%s]: OUTSIDE %s" % [i, j, a, b, c, d, p])
		return null
	#print("intersecting (%s,%s) [%s,%s] with [%s,%s]: %s NEW" % [i, j, a, b, c, d, p])
	# return the point rounded to the nearest integer coordinates
	return Vector2i(p.round())


# need canonical names for vertex_position
func reset_canvas() -> void:
	# clear the log
	log_text.clear()
	# delete all children of the canvas
	for child in canvas.get_children():
		canvas.remove_child(child)
	# add the background disc
	var background:Sprite2D = disc_2d(2.05, color_bkgd.color, 0.005)
	background.z_index = Layer.BACKGROUND
	canvas.add_child(background)
	# add the coloring parent
	coloring_parent = Node2D.new()
	canvas.add_child(coloring_parent)


func setup_find_next_intersection() -> void:
	show_search_edge(iter.i)
	show_search_edge(iter.j)
	infoln("intersecting edges: (%s, %s)" % [iter.i, iter.j])
	var p = line_segments_intersection(
		vertices[edges[iter.i].ends.x].position,
		vertices[edges[iter.i].ends.y].position,
		vertices[edges[iter.j].ends.x].position, 
		vertices[edges[iter.j].ends.y].position
	)
	if p != null:
		var idx:int
		if vertex_index.has("%s" % [p]):
			# existing vertex, update to include new incident edges
			idx = vertex_index["%s" % [p]]
			vertices[idx].incident_edges[iter.i] = true
			vertices[idx].incident_edges[iter.j] = true
		else:
			# new vertex
			info("\tintersection vertex: ")
			add_vertex(p, iter.i, iter.j)
			idx = vertices.size() - 1
		# add the vertex to the incident vertex dictionary of both edges
		edges[iter.i].incident_vertices[idx] = true
		edges[iter.j].incident_vertices[idx] = true


var skip_next_throttle:bool = false
func throttle(delta:float) -> bool:
	if skip_next_throttle:
		skip_next_throttle = false
		delta_accum = 0
		return false
	delta_accum += delta * 1000
	if delta_accum < slow_mo.value:
		return true
	delta_accum -= slow_mo.value
	return false


## compute N choose K
#func C(n:int, k:int) -> int:
	#if k == 0:
		#return 1
	#else:
		#return (n * C(n - 1, k - 1)) / k
#
#
## compute the sum of 1 to N
#func S(n:int) -> int:
	#return n * (n + 1) / 2


class CandidateIterator extends Object:
	
	var vertices:Array
	var edges:Array

	var v:int # current vertex
	var ie:Array # current incident edge set
	var e:Choose2Iterator # current incident edge pair
	var ivi:Array # incident edge set for edge e.i
	var ivj:Array # incident edge set for edge e.j
	var c:Choose2Iterator # candidate vertices iterator (c.i for edge e.i, c.j for edge e.j)
	
	
	func _init(vertices:Array, edges:Array) -> void:
		self.vertices = vertices
		self.edges = edges
		reset()


	func reset() -> void:
		v = 0
		#print("searching from vertex %s" % [v])
		ie = vertices[v].incident_edges.keys()
		#print( "  incident edge: %s" % [ie])
		e = Choose2Iterator.new(ie.size())
		e.next()
		#print("    trying edges %s and %s" % [ie[e.i], ie[e.j]])
		ivi = edges[ie[e.i]].incident_vertices.keys()
		#print("      edge %s incident vertices: %s" % [ie[e.i], ivi])
		ivj = edges[ie[e.j]].incident_vertices.keys()
		#print("      edge %s incident vertices: %s" % [ie[e.j], ivj])
		c = Choose2Iterator.new(ivi.size(), ivj.size())
	
	
	func next() -> bool:
		if c.next():
			# next candidate pair selected, return true
			return true
		else:
			if e.next():
				# reset for next pair of edges
				#print("    trying edges %s and %s" % [ie[e.i], ie[e.j]])
				ivi = edges[ie[e.i]].incident_vertices.keys()
				#print("      edge %s incident vertices: %s" % [ie[e.i], ivi])
				ivj = edges[ie[e.j]].incident_vertices.keys()
				#print("      edge %s incident vertices: %s" % [ie[e.j], ivj])
				c = Choose2Iterator.new(ivi.size(), ivj.size())
				c.next()
				return true
			else:
				if v < vertices.size() - 1:
					# reset for next vertex
					v += 1
					#print("searching from vertex %s" % [v])
					ie = vertices[v].incident_edges.keys()
					#print( "  incident edge list: %s" % [ie])
					e = Choose2Iterator.new(ie.size())
					e.next()
					#print("    trying edges %s and %s" % [ie[e.i], ie[e.j]])
					ivi = edges[ie[e.i]].incident_vertices.keys()
					#print("      edge %s incident vertices: %s" % [ie[e.i], ivi])
					ivj = edges[ie[e.j]].incident_vertices.keys()
					#print("      edge %s incident vertices: %s" % [ie[e.j], ivj])
					c = Choose2Iterator.new(ivi.size(), ivj.size())
					c.next()
					return true
				else:
					return false
	
	
	func candidate() -> Vector3i:
		#print("        candidate %s" % [Vector3i(v, ivi[c.i], ivj[c.j])])
		return Vector3i(v, ivi[c.i], ivj[c.j])
	

	func dump() -> void:
		print("v = %s, e.n = %s, e.i = %s, e.j = %s, c.n = %s, c.m = %s, c.i = %s, c.j = %s" % [v, e.n, e.i, e.j, c.n, c.m, c.i, c.j])


class Choose2Iterator extends Object:
	
	var n:int
	var m:int
	var i:int
	var j:int
	

	# m == 0 ==> one list, n items
	# m != 0 ==> two lists, n items and m items
	func _init(n:int, m:int = 0) -> void:
		self.n = n
		self.m = m
		self.reset()
	
	
	func reset() -> void:
		i = 0
		if m == 0:
			j = 0
		else:
			j = -1

	
	func next() -> bool:
		if m == 0:
			if j < n - 1:
				j += 1
				return true
			else:
				if i < n - 2:
					i += 1
					j = i + 1
					return true
				else:
					return false
		else:
			if j < m - 1:
				j += 1
				return true
			else:
				if i < n - 1:
					i += 1
					j = 0
					return true
				else:
					return false
	
#func _input(_event:InputEvent) -> void:
	#if _event is InputEventKey and _event.keycode == KEY_ESCAPE and not _event.is_pressed():
		#get_tree().quit()
