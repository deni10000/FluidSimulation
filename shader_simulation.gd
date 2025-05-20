extends Node2D

var fps:
	set(value):
		%Fps.text = str(1 / value)
var radius: float = 2
var smoothing_radius: float = 10
var count: int = 30000
	#set(val):
		#count = val
		#set_particles()
var spacing = 10:
	set(val):
		spacing = val
		set_particles()	
var shader_local_size = 256
var viscosity_multiplier = 10

var int_size = 4
var hash_oversizing = 2
var img_size_x = 1500
var img_size_y = 1000

var output_tex_uniform :RDUniform
var output_tex := RID()
var fmt := RDTextureFormat.new() 

var view := RDTextureView.new()

var positions: PackedVector2Array = []
var shader :RID
var pipeline :RID
var sum_shader: RID
var sum_pipeline: RID
var uniform_set :RID
var first_step_sum_uniform_set: RID
var second_step_sum_uniform_set: RID

var positions_buffer: RID
var predicated_positions_buffer: RID
var velocity_buffer: RID
var density_buffer: RID
var hash_count_buffer: RID
var pref_sum_hash_count_buffer: RID
var pref_sum_hash_count_buffer2: RID
var hash_indexes_buffer: RID
var force_buffer: RID

var positions_uniform :RDUniform
var predicated_positions_uniform :RDUniform
var velocity_uniform :RDUniform
var density_uniform :RDUniform
var hash_count_uniform :RDUniform
var pref_sum_hash_count_uniform :RDUniform
var pref_sum_hash_count_uniform2 :RDUniform
var hash_indexes_uniform :RDUniform
var in_hash_pref_uniform: RDUniform
var out_has_pref_uniform: RDUniform
var force_buffer_uniform: RDUniform

var gravity: float = 70
var default_density: float = 100
var pressure_multiply: float = 50000
var damping: float = 0.3
var rows = 20
var mass: float = 6:
	set(val):
		mass = val

var rd := RenderingServer.create_local_rendering_device()
var hash_count: PackedInt32Array
var pref_sum_hash_count: PackedInt32Array
var hash_indexes: PackedInt32Array

func coord_to_cell_pos(pos: Vector2) -> Vector2i:
	return Vector2i(pos /  smoothing_radius)

func cell_hash(pos: Vector2i):
	var a = abs(pos.x) * 15823
	var b = abs(pos.y) * 9737333
	return a + b

func fill_hash_grid():
	hash_indexes.resize(count)
	
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

func _ready() -> void:
	%ViscositySpinBox.value = viscosity_multiplier
	%SpinBox.value = count
	%SpacingSpinBox.value = radius
	%SmoothingSpinBox.value = smoothing_radius
	%DensitySpinBox.value = default_density
	%SpinBox2.value = pressure_multiply
	%GravitySpinBox.value = gravity
	%MassSpinBox.value = mass
	get_tree().paused = true
	
	fmt.width = img_size_x
	fmt.height = img_size_y
	fmt.format = RenderingDevice.DATA_FORMAT_R32G32B32A32_SFLOAT
	fmt.usage_bits = RenderingDevice.TEXTURE_USAGE_CAN_UPDATE_BIT \
					| RenderingDevice.TEXTURE_USAGE_STORAGE_BIT \
					| RenderingDevice.TEXTURE_USAGE_CAN_COPY_FROM_BIT \
					| RenderingDevice.TEXTURE_USAGE_CPU_READ_BIT
	
	for i in range(count):
		positions.append(Vector2(randi() % 600 , randi() % 600))
	rebuild_buffers()

func set_particles():
	positions.clear()
	var start_pos = Vector2(100, 100)
	var diameter = 2 * radius + spacing
	for i in range(count):
		positions.append(start_pos + Vector2(diameter * (i / rows), diameter * (i % rows)))
	rebuild_buffers()

func params_to_byte_array(params):
	var data: PackedByteArray
	for x in params:
		if x is int:
			var dop: PackedInt32Array = [x] 
			data.append_array(dop.to_byte_array())
		else:
			var dop: PackedFloat32Array = [x]
			data.append_array(dop.to_byte_array())
	return data


#func _draw() -> void:
	#for x in positions:
		#draw_circle(x, radius, Color.BLUE)
		
func _process(delta: float) -> void:
	fps = delta
	var global_size = (count/shader_local_size)+1
	var hash_size = ((count * hash_oversizing) / shader_local_size) + 1
	
	var compute_list = rd.compute_list_begin()
	rd.compute_list_bind_compute_pipeline(compute_list, pipeline)
	rd.compute_list_bind_uniform_set(compute_list, uniform_set, 0)
	var data
	# shader PUSH CONSTANT params
	var params = [0, radius, smoothing_radius, gravity, default_density, pressure_multiply, damping, count, count * hash_oversizing, mass, delta, img_size_x, img_size_y, viscosity_multiplier, get_local_mouse_position().x, get_local_mouse_position().y]
	
	params[0] = -1
	data = params_to_byte_array(params)
	rd.compute_list_set_push_constant(compute_list, data, data.size())
	rd.compute_list_dispatch(compute_list, hash_size, 1, 1)	
	
	params[0] = 3
	data = params_to_byte_array(params)
	rd.compute_list_set_push_constant(compute_list, data, data.size())
	rd.compute_list_dispatch(compute_list, global_size, 1, 1)
	
	params[0] = 0
	data = params_to_byte_array(params)
	rd.compute_list_set_push_constant(compute_list, data, data.size())
	rd.compute_list_dispatch(compute_list, hash_size, 1, 1)
	rd.compute_list_add_barrier(compute_list)
	
	params[0] = 1
	data = params_to_byte_array(params)
	rd.compute_list_set_push_constant(compute_list, data, data.size())
	rd.compute_list_dispatch(compute_list, global_size, 1, 1)
	rd.compute_list_add_barrier(compute_list)
	
	rd.compute_list_bind_compute_pipeline(compute_list, sum_pipeline)
	var step = 1
	var ln = count * hash_oversizing * 2
	var i = 1
	while step < ln:
		if i % 2:
			rd.compute_list_bind_uniform_set(compute_list, first_step_sum_uniform_set, 0)
		else:
			rd.compute_list_bind_uniform_set(compute_list, second_step_sum_uniform_set, 0)
		i += 1
		data = params_to_byte_array([step, 0, 0, 0])
		rd.compute_list_set_push_constant(compute_list, data , data.size())
		rd.compute_list_dispatch(compute_list, hash_size, 1, 1)
		rd.compute_list_add_barrier(compute_list)
		step *= 2
	
	rd.compute_list_bind_compute_pipeline(compute_list, pipeline)
	rd.compute_list_bind_uniform_set(compute_list, uniform_set, 0)
	
	params[0] = 2
	data = params_to_byte_array(params)
	rd.compute_list_set_push_constant(compute_list, data, data.size())
	rd.compute_list_dispatch(compute_list, global_size, 1, 1)
	rd.compute_list_add_barrier(compute_list)
	
	params[0] = 4
	data = params_to_byte_array(params)
	rd.compute_list_set_push_constant(compute_list, data, data.size())
	rd.compute_list_dispatch(compute_list, global_size, 1, 1)
	rd.compute_list_add_barrier(compute_list)
	
	params[0] = 5
	data = params_to_byte_array(params)
	rd.compute_list_set_push_constant(compute_list, data, data.size())
	rd.compute_list_dispatch(compute_list, global_size, 1, 1)
	rd.compute_list_add_barrier(compute_list)
	
	params[0] = 6
	data = params_to_byte_array(params)
	rd.compute_list_set_push_constant(compute_list, data, data.size())
	rd.compute_list_dispatch(compute_list, global_size, 1, 1)
	rd.compute_list_add_barrier(compute_list)
	
	rd.compute_list_end()
	rd.submit()
	rd.sync()
	
	var image = Image.create_from_data(img_size_x, img_size_y, false, Image.FORMAT_RGBAF, rd.texture_get_data(output_tex, 0))
	
	%TextureRect.texture.update(image)
	
	#positions = Utility.float_byte_array_to_Vector2Array(rd.buffer_get_data(positions_buffer))
	#queue_redraw()
	

func get_buffer_uniform(binding, buffer) -> RDUniform:
	var unif := RDUniform.new()
	unif.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER
	unif.binding = binding
	unif.add_id(buffer)
	return unif

func rebuild_buffers():
	# load and begin compiling compute shader
	var shader_file :RDShaderFile= load("uid://blbluf43jc54l")
	var shader_spirv :RDShaderSPIRV= shader_file.get_spirv()
	shader = rd.shader_create_from_spirv(shader_spirv)
	pipeline = rd.compute_pipeline_create(shader)
	
	var pref_sum: RDShaderFile = load("uid://b7u0trucvfk1p")
	var shader_pref_spirv: RDShaderSPIRV = pref_sum.get_spirv()
	sum_shader = rd.shader_create_from_spirv(shader_pref_spirv)
	sum_pipeline = rd.compute_pipeline_create(sum_shader)
	#var arr: PackedInt32Array
	#for i in range(hash_oversizing * positions.size()):
		#arr.append(i)
	pref_sum_hash_count_buffer = rd.storage_buffer_create(int_size * hash_oversizing * positions.size())
	pref_sum_hash_count_buffer2 = rd.storage_buffer_create(int_size * hash_oversizing * positions.size())
	
	var unif1 := get_buffer_uniform(0, pref_sum_hash_count_buffer)
	var unif2 := get_buffer_uniform(1, pref_sum_hash_count_buffer2)
	first_step_sum_uniform_set = rd.uniform_set_create([unif1, unif2], sum_shader, 0)
	
	unif1.binding = 1
	unif2.binding = 0
	second_step_sum_uniform_set = rd.uniform_set_create([unif1, unif2], sum_shader, 0)
	
	var data = positions.to_byte_array()
	positions_buffer = rd.storage_buffer_create(data.size(), data)
	predicated_positions_buffer = rd.storage_buffer_create(data.size())
	velocity_buffer = rd.storage_buffer_create(data.size())
	density_buffer = rd.storage_buffer_create(int_size * positions.size())
	hash_count_buffer = rd.storage_buffer_create(int_size * hash_oversizing * positions.size())
	hash_indexes_buffer = rd.storage_buffer_create(int_size * positions.size())
	force_buffer = rd.storage_buffer_create(data.size())
	
	var output_image := Image.create(img_size_x, img_size_y, false, Image.FORMAT_RGBAF)
	var image_texture := ImageTexture.create_from_image(output_image)
	%TextureRect.texture = image_texture
	output_tex = rd.texture_create(fmt, view, [output_image.get_data()])
	
	positions_uniform                = get_buffer_uniform(0, positions_buffer)
	predicated_positions_uniform     = get_buffer_uniform(1, predicated_positions_buffer)
	velocity_uniform                 = get_buffer_uniform(2, velocity_buffer)
	density_uniform                  = get_buffer_uniform(3, density_buffer)
	hash_count_uniform               = get_buffer_uniform(4, hash_count_buffer)
	pref_sum_hash_count_uniform      = get_buffer_uniform(5, pref_sum_hash_count_buffer)
	hash_indexes_uniform             = get_buffer_uniform(6, hash_indexes_buffer)
	pref_sum_hash_count_uniform2      = get_buffer_uniform(7, pref_sum_hash_count_buffer2)
	force_buffer_uniform = get_buffer_uniform(9, force_buffer)
	
	output_tex_uniform = RDUniform.new()
	output_tex_uniform.uniform_type = RenderingDevice.UNIFORM_TYPE_IMAGE
	output_tex_uniform.binding = 8
	output_tex_uniform.add_id(output_tex)
	
	uniform_set = rd.uniform_set_create([positions_uniform, 
	predicated_positions_uniform, 
	velocity_uniform, 
	density_uniform, 
	hash_count_uniform, 
	pref_sum_hash_count_uniform, 
	hash_indexes_uniform, 
	output_tex_uniform, 
	pref_sum_hash_count_uniform2, 
	force_buffer_uniform], shader, 0)
	
func _on_spin_box_value_changed(value: float) -> void:
	count = value


func _on_spacing_spin_box_value_changed(value: float) -> void:
	radius = value


func _on_pause_button_pressed() -> void:
	get_tree().paused = not get_tree().paused

func _on_smoothing_spin_box_value_changed(value: float) -> void:
	smoothing_radius = value


func _on_density_spin_box_value_changed(value: float) -> void:
	default_density = value / 1000


func _on_next_step_button_pressed() -> void:
	if get_tree().paused:
		_process(0.1)


func _on_spin_box_2_value_changed(value: float) -> void:
	pressure_multiply = value


func _on_gravity_spin_box_value_changed(value: float) -> void:
	gravity = value


func _on_mass_spin_box_value_changed(value: float) -> void:
	mass = value


func _on_viscosity_spin_box_value_changed(value: float) -> void:
	viscosity_multiplier = value
