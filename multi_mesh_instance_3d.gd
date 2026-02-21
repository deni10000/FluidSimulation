extends Node3D

var mm_rid : RID   # MultiMesh RID
var inst_count := 100

func _ready():
	var mm = MultiMesh.new()
	mm.use_colors = true
	mm.transform_format = MultiMesh.TRANSFORM_3D
	mm.instance_count = inst_count

	var sphere := SphereMesh.new()
	sphere.radius = 0.2
	sphere.height = 0.4
	sphere.radial_segments = 12
	sphere.rings = 6
	
	var mat := StandardMaterial3D.new()
	mat.vertex_color_use_as_albedo = true 
	sphere.material = mat
	
	mm.mesh = sphere
	mm_rid = mm.get_rid()
	
	var mi := MultiMeshInstance3D.new()
	mi.multimesh = mm
	add_child(mi)

	# Важно: связать high-level MultiMesh с нашим low-level RID
	#mi.multimesh.set_multimesh(mm_rid)

	# 6. Инициализируем позиции
	_randomize_positions()

	# Обновлять будем каждый кадр
	set_process(true)
	mm.set_instance_color(0, Color.RED)


func _randomize_positions():
	for i in range(inst_count):
		var t := Transform3D()
		var pos := Vector3(
			randf_range(-5, 5),
			randf_range(-2, 2),
			randf_range(-5, 5)
		)
		t.origin = pos
		RenderingServer.multimesh_instance_set_transform(mm_rid, i, t)

		var col := Color(randf(), randf(), randf())
		RenderingServer.multimesh_instance_set_color(mm_rid, i, col)
		


func _process(delta):
	# Просто вращаем первый инстанс вокруг Y
	var t := RenderingServer.multimesh_instance_get_transform(mm_rid, 0)
	
	t.origin = t.origin.rotated(Vector3.UP, delta)
	RenderingServer.multimesh_instance_set_transform(mm_rid, 0, t)
