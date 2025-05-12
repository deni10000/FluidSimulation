extends Node2D
var radius = 4
var smoothing_radius = 20
var count = 300:
	set(val):
		count = val
		set_particles()
var spacing = 10:
	set(val):
		spacing = val
		set_particles()
var positions: PackedVector2Array = []
var predicated_positions: PackedVector2Array = []
var velocity: PackedVector2Array = []
var density: PackedFloat32Array = []
var gravity = 150
var default_density = 2
var pressure_multiply = 10000
var damping = 0.5
var rows = 20
var mass = 5000
var hash_count: PackedInt32Array
var pref_sum_hash_count: PackedInt32Array
var hash_indexes: PackedInt32Array



func _draw() -> void:
	for x in positions:
		draw_circle(x, radius, Color.BLUE)

func pow3_smoothing(radius, dst):
	if dst >= radius: return 0
	
	#var v = PI * radius ** 5 / 10
	#var ret = (radius - dst) ** 3 / v
	#return ret
	var v = (PI * (radius ** 4)) / 6
	return ((radius - dst) ** 2) / v

func pow2_smoothing(radius, dst):
	if dst >= radius: return 0
	
	#var v = -PI * radius ** 4 / 2
	#var ret = -3 * (radius - dst) ** 2 / v
	#return ret
	var scale = 12 / ((radius ** 4) * PI)
	return (dst - radius) * scale 

func density_to_pressure(density: float):
	return (density - default_density) * pressure_multiply

func shared_pressure(density1:float, density2:float):
	return (density_to_pressure(density1) + density_to_pressure(density2)) / 2

func coord_to_cell_pos(pos: Vector2) -> Vector2i:
	return Vector2i(pos /  smoothing_radius)

func cell_hash(pos: Vector2i):
	var a = abs(pos.x) * 15823
	var b = abs(pos.y) * 9737333
	return a + b
	

func fill_hash_grid():
	var size = len(positions) * 2
	var count: PackedInt32Array
	count.resize(size)
	for x in positions:
		count[cell_hash(coord_to_cell_pos(x)) % size] += 1
	hash_count = count.duplicate()
	count[0] -= 1
	for i in range(1, size):
		count[i] += count[i - 1]
	pref_sum_hash_count = count.duplicate()
	for i in range(len(positions)):
		var hash = cell_hash(coord_to_cell_pos(positions[i])) % size
		hash_indexes[count[hash]] = i
		count[hash] -= 1
		
	
	

func get_near_particles(index, radius):
	var cell_position = coord_to_cell_pos(positions[index])
	var ret: PackedInt32Array = []
	var used_hash: PackedInt32Array = []
	for i in range(cell_position.x - 1, cell_position.x + 2):
		for j in range(cell_position.y - 1, cell_position.y + 2):
			var hash = cell_hash(Vector2i(i, j)) % len(hash_count)
			if hash in used_hash:
				continue
			used_hash.append(hash)
			var cnt = hash_count[hash]
			var start_index = pref_sum_hash_count[hash] 
			for k in range(start_index, start_index - cnt, -1):
				ret.append(hash_indexes[k])
	return ret
			
	

func get_force(j, radius):
	var pressure_force = Vector2(0, 0)
	for i in get_near_particles(j, radius):
		if i == j or density[i] == 0: continue
		
		var vec = (predicated_positions[i] - predicated_positions[j])
		var dst = vec.length()
		var slope = pow2_smoothing(radius, dst)
		var dir
		if dst != 0:
			dir = vec / dst
		else:
			var x = randf_range(0, 1)
			var y =  (1 - x ** 2) ** 0.5
			dir = Vector2(x, y)
		pressure_force += shared_pressure(density[i], density[j]) * dir * slope * mass / density[i]
	return pressure_force
		
	
	

func get_density(j, radius):
	var density = 0
	var sample_point := predicated_positions[j]
	for i in get_near_particles(j, radius):
		#if i == j: continue
		var dst = (predicated_positions[i] - sample_point).length()
		density += pow3_smoothing(radius, dst) * mass
	return density

func move_particles(delta):
	var smoothing_radius = self.smoothing_radius
	var radius = self.radius
	var screen_seze = get_viewport_rect().size
	var tasks = []
	fill_hash_grid()
	for i in range(count):
		velocity[i] += gravity * Vector2.DOWN * delta
		predicated_positions[i] = positions[i] + velocity[i] / 60.0
	
	for i in range(count):
		var task := func():
			density[i] = get_density(i, smoothing_radius)
		tasks.append(WorkerThreadPool.add_task(task))
	for t in tasks:
		WorkerThreadPool.wait_for_task_completion(t)
	tasks.clear()
	for i in range(count):
		var task := func():
			var force = get_force(i, smoothing_radius)
			velocity[i] += (force / density[i]) * delta
			positions[i] += velocity[i] * delta
			
			if positions[i].x < radius:
				positions[i].x = radius
				velocity[i].x *= -1 * damping
			if positions[i].y < radius:
				positions[i].y = radius
				velocity[i].y *= -1 * damping
			if positions[i].x > screen_seze.x - radius:
				positions[i].x = screen_seze.x - radius
				velocity[i].x *= -1 * damping
			if positions[i].y > screen_seze.y - radius:
				positions[i].y = screen_seze.y - radius
				velocity[i].y *= -1 * damping
		tasks.append(WorkerThreadPool.add_task(task))
	for t in tasks:
		WorkerThreadPool.wait_for_task_completion(t)
		
		#var task = func():
		#tasks.append(WorkerThreadPool.add_task(task))
	#for t in tasks:
		#await t

func set_particles():
	positions.clear()
	velocity.clear()
	density.clear()
	hash_indexes.clear()
	predicated_positions.clear()
	var start_pos = Vector2(100, 100)
	var diameter = 2 * radius + spacing
	for i in range(count):
		positions.append(start_pos + Vector2(diameter * (i / rows), diameter * (i % rows)))
		velocity.append(Vector2(0, 0))
		density.append(0)
		hash_indexes.append(0)
		predicated_positions.append(Vector2.ZERO)
	queue_redraw()
		
func _ready() -> void:
	%SpinBox.value = count
	%SpacingSpinBox.value = spacing
	%SmoothingSpinBox.value = smoothing_radius
	%DensitySpinBox.value = default_density
	%SpinBox2.value = pressure_multiply
	%GravitySpinBox.value = gravity
	get_tree().paused = true

func encode_positions(positions: Array[Vector2]) -> ImageTexture:
	var img := Image.create_empty(positions.size(), 1, false, Image.Format.FORMAT_RGBAF)
	for i in range(positions.size()):
		img.set_pixel(i, 0, Color(positions[i].x, positions[i].y, 0, 1))
	var tex := ImageTexture.create_from_image(img)
	return tex

func fill_phone():
	%TextureRect.size = get_viewport_rect().size
	var shader_material: ShaderMaterial = %TextureRect.material
	shader_material.set_shader_parameter("positions_tex", positions)
	shader_material.set_shader_parameter("mass", mass)
	shader_material.set_shader_parameter("particle_count", positions.size())
	shader_material.set_shader_parameter("radius", smoothing_radius)
	shader_material.set_shader_parameter("target_density", default_density)
	shader_material.set_shader_parameter("texture_size", get_viewport_rect().size)
	

func _process(delta: float) -> void:
	move_particles(delta)
	fill_phone()
	queue_redraw()


func _on_spin_box_value_changed(value: float) -> void:
	count = value


func _on_spacing_spin_box_value_changed(value: float) -> void:
	spacing = value


func _on_pause_button_pressed() -> void:
	get_tree().paused = not get_tree().paused


func _on_smoothing_spin_box_value_changed(value: float) -> void:
	smoothing_radius = value


func _on_density_spin_box_value_changed(value: float) -> void:
	default_density = value


func _on_next_step_button_pressed() -> void:
	if get_tree().paused:
		_process(0.1)


func _on_spin_box_2_value_changed(value: float) -> void:
	pressure_multiply = value


func _on_gravity_spin_box_value_changed(value: float) -> void:
	gravity = value
