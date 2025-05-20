using Godot;
using System;
using System.IO;

public partial class ShaderSimulation : Node2D
{
	private SpinBox _viscositySpinBox;
	private SpinBox _countSpinBox;
	private SpinBox _spacingSpinBox;
	private SpinBox _smoothingSpinBox;
	private SpinBox _densitySpinBox;
	private SpinBox _pressureSpinBox;
	private SpinBox _gravitySpinBox;
	private SpinBox _massSpinBox;
	private Label _fpsLabel;
	private TextureRect _textureRect;

	private float _fps;
	public float Fps 
	{ 
		get => _fps;
		set 
		{
			_fps = value;
			if (_fpsLabel != null)
				_fpsLabel.Text = (1.0f / value).ToString("F2");
		}
	}

	private float _radius = 2.0f;
	private float _smoothingRadius = 10.0f;
	
	private int _count = 30000;
	public int Count 
	{ 
		get => _count;
		set 
		{
			_count = value;
			SetParticles();
		}
	}

	private int _spacing = 10;
	public int Spacing 
	{ 
		get => _spacing;
		set 
		{
			_spacing = value;
			SetParticles();
		}
	}

	private int _shaderLocalSize = 512;
	private float _viscosityMultiplier = 10.0f;

	private int _intSize = 4;
	private int _hashOversizing = 2;
	private int _imgSizeX = 1500;
	private int _imgSizeY = 1000;

	private RDUniform _outputTexUniform;
	private Rid _outputTex;
	private RDTextureFormat _fmt;
	private RDTextureView _view;

	private Vector2[] _positions = Array.Empty<Vector2>();
	private Rid _shader;
	private Rid _pipeline;
	private Rid _sumShader;
	private Rid _sumPipeline;
	private Rid _uniformSet;
	private Rid _firstStepSumUniformSet;
	private Rid _secondStepSumUniformSet;

	private Rid _positionsBuffer;
	private Rid _predicatedPositionsBuffer;
	private Rid _velocityBuffer;
	private Rid _densityBuffer;
	private Rid _hashCountBuffer;
	private Rid _prefSumHashCountBuffer;
	private Rid _prefSumHashCountBuffer2;
	private Rid _hashIndexesBuffer;
	private Rid _forceBuffer;

	private RDUniform _positionsUniform;
	private RDUniform _predicatedPositionsUniform;
	private RDUniform _velocityUniform;
	private RDUniform _densityUniform;
	private RDUniform _hashCountUniform;
	private RDUniform _prefSumHashCountUniform;
	private RDUniform _prefSumHashCountUniform2;
	private RDUniform _hashIndexesUniform;
	private RDUniform _forceBufferUniform;

	private float _gravity = 70.0f;
	private float _defaultDensity = 3.0f;
	private float _pressureMultiply = 2500.0f;
	private float _damping = 0.3f;
	private int _rows = 20;
	
	private float _mass = 6.0f;
	public float Mass 
	{ 
		get => _mass;
		set => _mass = value;
	}

	private RenderingDevice _rd;
	private int[] _hashCount = Array.Empty<int>();
	private int[] _prefSumHashCount = Array.Empty<int>();
	private int[] _hashIndexes = Array.Empty<int>();

	public override void _Ready()
	{
		GD.Print("aagag");
		// Get UI elements
		_viscositySpinBox = GetNode<SpinBox>("%ViscositySpinBox");
		_countSpinBox = GetNode<SpinBox>("%SpinBox");
		_spacingSpinBox = GetNode<SpinBox>("%SpacingSpinBox");
		_smoothingSpinBox = GetNode<SpinBox>("%SmoothingSpinBox");
		_densitySpinBox = GetNode<SpinBox>("%DensitySpinBox");
		_pressureSpinBox = GetNode<SpinBox>("%SpinBox2");
		_gravitySpinBox = GetNode<SpinBox>("%GravitySpinBox");
		_massSpinBox = GetNode<SpinBox>("%MassSpinBox");
		_fpsLabel = GetNode<Label>("%Fps");
		_textureRect = GetNode<TextureRect>("%TextureRect");

		// Set initial values
		_viscositySpinBox.Value = _viscosityMultiplier;
		_countSpinBox.Value = _count;
		_spacingSpinBox.Value = _spacing;
		_smoothingSpinBox.Value = _smoothingRadius;
		_densitySpinBox.Value = _defaultDensity;
		_pressureSpinBox.Value = _pressureMultiply;
		_gravitySpinBox.Value = _gravity;
		_massSpinBox.Value = _mass;

		GetTree().Paused = true;

		// Initialize texture format
		_fmt = new RDTextureFormat();
		_fmt.Width = (uint)_imgSizeX;
		_fmt.Height = (uint)_imgSizeY;
		_fmt.Format = RenderingDevice.DataFormat.R32G32B32A32Sfloat;
		_fmt.UsageBits = RenderingDevice.TextureUsageBits.CanUpdateBit |
						RenderingDevice.TextureUsageBits.StorageBit |
						RenderingDevice.TextureUsageBits.CanCopyFromBit |
						RenderingDevice.TextureUsageBits.CpuReadBit;

		_view = new RDTextureView();

		// Initialize positions randomly
		var random = new Random();
		_positions = new Vector2[_count];
		for (int i = 0; i < _count; i++)
		{
			_positions[i] = new Vector2(random.Next(0, 600), random.Next(0, 600));
		}

		_rd = RenderingServer.CreateLocalRenderingDevice();
		RebuildBuffers();
	}

	private Vector2I CoordToCellPos(Vector2 pos)
	{
		return new Vector2I((int)(pos.X / _smoothingRadius), (int)(pos.Y / _smoothingRadius));
	}

	private int CellHash(Vector2I pos)
	{
		int a = Math.Abs(pos.X) * 15823;
		int b = Math.Abs(pos.Y) * 9737333;
		return a + b;
	}

	private void FillHashGrid()
	{
		Array.Resize(ref _hashIndexes, _count);
		
		int size = _positions.Length * 2;
		int[] count = new int[size];
		
		foreach (var pos in _positions)
		{
			count[CellHash(CoordToCellPos(pos)) % size] += 1;
		}
		
		_hashCount = new int[count.Length];
		Array.Copy(count, _hashCount, count.Length);
		
		count[0] -= 1;
		for (int i = 1; i < size; i++)
		{
			count[i] += count[i - 1];
		}
		
		_prefSumHashCount = new int[count.Length];
		Array.Copy(count, _prefSumHashCount, count.Length);
		
		for (int i = 0; i < _positions.Length; i++)
		{
			int hash = CellHash(CoordToCellPos(_positions[i])) % size;
			_hashIndexes[count[hash]] = i;
			count[hash] -= 1;
		}
	}

	private void SetParticles()
	{
		_positions = new Vector2[_count];
		Vector2 startPos = new Vector2(100, 100);
		float diameter = 2 * _radius + _spacing;
		
		for (int i = 0; i < _count; i++)
		{
			_positions[i] = startPos + new Vector2(diameter * (i / _rows), diameter * (i % _rows));
		}
		
		RebuildBuffers();
	}

	private byte[] ParamsToByteArray(object[] parameters)
	{
		using var ms = new MemoryStream(parameters.Length * 4);
		foreach (var p in parameters)
		{
			switch (p)
			{
				case int i:
					ms.Write(BitConverter.GetBytes(i), 0, 4);
					break;
				case float f:
					ms.Write(BitConverter.GetBytes(f), 0, 4);
					break;
				default:
					throw new ArgumentException($"Unsupported parameter type: {p.GetType()}");
			}
		}
		return ms.ToArray();
	}

	public override void _Process(double delta)
	{
		int globalSize = (_count / _shaderLocalSize) + 1;
		int hashSize = ((_count * _hashOversizing) / _shaderLocalSize) + 1;

		long computeList = _rd.ComputeListBegin();
		_rd.ComputeListBindComputePipeline(computeList, _pipeline);
		_rd.ComputeListBindUniformSet(computeList, _uniformSet, 0);

		Vector2 mousePos = GetLocalMousePosition();
		object[] parameters = {
			0, _radius, _smoothingRadius, _gravity, _defaultDensity, _pressureMultiply,
			_damping, _count, _count * _hashOversizing, _mass, (float)delta,
			_imgSizeX, _imgSizeY, _viscosityMultiplier, mousePos.X, mousePos.Y
		};

		// Step 3: Update hash
		parameters[0] = 3;
		byte[] data = ParamsToByteArray(parameters);
		_rd.ComputeListSetPushConstant(computeList, data, (uint)data.Length);
		_rd.ComputeListDispatch(computeList, (uint)globalSize, 1u, 1u);
		_rd.ComputeListAddBarrier(computeList);

		// Step 0: Clear hash
		parameters[0] = 0;
		data = ParamsToByteArray(parameters);
		_rd.ComputeListSetPushConstant(computeList, data, (uint)data.Length);
		_rd.ComputeListDispatch(computeList, (uint)hashSize, 1u, 1u);
		_rd.ComputeListAddBarrier(computeList);

		// Step 1: Density calculation
		parameters[0] = 1;
		data = ParamsToByteArray(parameters);
		_rd.ComputeListSetPushConstant(computeList, data, (uint)data.Length);
		_rd.ComputeListDispatch(computeList, (uint)globalSize, 1u, 1u);
		_rd.ComputeListAddBarrier(computeList);

		// Prefix sum calculations
		_rd.ComputeListBindComputePipeline(computeList, _sumPipeline);
		int step = 1;
		int ln = _count * _hashOversizing * 2;
		int i = 1;
		
		while (step < ln)
		{
			if (i % 2 == 1)
				_rd.ComputeListBindUniformSet(computeList, _firstStepSumUniformSet, 0);
			else
				_rd.ComputeListBindUniformSet(computeList, _secondStepSumUniformSet, 0);
			
			i++;
			object[] sumParams = { step, 0, 0, 0 };
			data = ParamsToByteArray(sumParams);
			_rd.ComputeListSetPushConstant(computeList, data, (uint)data.Length);
			_rd.ComputeListDispatch(computeList, (uint)hashSize, 1u, 1u);
			_rd.ComputeListAddBarrier(computeList);
			step *= 2;
		}

		// Continue with main pipeline
		_rd.ComputeListBindComputePipeline(computeList, _pipeline);
		_rd.ComputeListBindUniformSet(computeList, _uniformSet, 0);

		// Step 2: Create hash indexes
		parameters[0] = 2;
		data = ParamsToByteArray(parameters);
		_rd.ComputeListSetPushConstant(computeList, data, (uint)data.Length);
		_rd.ComputeListDispatch(computeList, (uint)globalSize, 1u, 1u);
		_rd.ComputeListAddBarrier(computeList);

		// Step 4: Calculate pressure force
		parameters[0] = 4;
		data = ParamsToByteArray(parameters);
		_rd.ComputeListSetPushConstant(computeList, data, (uint)data.Length);
		_rd.ComputeListDispatch(computeList, (uint)globalSize, 1u, 1u);
		_rd.ComputeListAddBarrier(computeList);

		// Step 5: Calculate viscosity force
		parameters[0] = 5;
		data = ParamsToByteArray(parameters);
		_rd.ComputeListSetPushConstant(computeList, data, (uint)data.Length);
		_rd.ComputeListDispatch(computeList, (uint)globalSize, 1u, 1u);
		_rd.ComputeListAddBarrier(computeList);

		// Step 6: Integrate
		parameters[0] = 6;
		data = ParamsToByteArray(parameters);
		_rd.ComputeListSetPushConstant(computeList, data, (uint)data.Length);
		_rd.ComputeListDispatch(computeList, (uint)globalSize, 1u, 1u);
		_rd.ComputeListAddBarrier(computeList);

		_rd.ComputeListEnd();
		_rd.Submit();
		_rd.Sync();

		// Update texture
		var imageData = _rd.TextureGetData(_outputTex, 0);
		var image = Image.CreateFromData(_imgSizeX, _imgSizeY, false, Image.Format.Rgbaf, imageData);
		
		if (_textureRect.Texture is ImageTexture imageTexture)
		{
			imageTexture.Update(image);
		}
	}

	private RDUniform GetBufferUniform(int binding, Rid buffer)
	{
		var uniform = new RDUniform();
		uniform.UniformType = RenderingDevice.UniformType.StorageBuffer;
		uniform.Binding = binding;
		uniform.AddId(buffer);
		return uniform;
	}

	private void RebuildBuffers()
	{
		// Load and compile compute shaders
		var shaderFile = GD.Load<RDShaderFile>("uid://blbluf43jc54l");
		var shaderSpirv = shaderFile.GetSpirV();
		_shader = _rd.ShaderCreateFromSpirV(shaderSpirv);
		_pipeline = _rd.ComputePipelineCreate(_shader);

		var prefSumShaderFile = GD.Load<RDShaderFile>("uid://b7u0trucvfk1p");
		var prefSumShaderSpirv = prefSumShaderFile.GetSpirV();
		_sumShader = _rd.ShaderCreateFromSpirV(prefSumShaderSpirv);
		_sumPipeline = _rd.ComputePipelineCreate(_sumShader);

		// Create buffers
		_prefSumHashCountBuffer = _rd.StorageBufferCreate((uint)(_intSize * _hashOversizing * _positions.Length));
		_prefSumHashCountBuffer2 = _rd.StorageBufferCreate((uint)(_intSize * _hashOversizing * _positions.Length));

		var unif1 = GetBufferUniform(0, _prefSumHashCountBuffer);
		var unif2 = GetBufferUniform(1, _prefSumHashCountBuffer2);
		_firstStepSumUniformSet = _rd.UniformSetCreate(new Godot.Collections.Array<RDUniform> { unif1, unif2 }, _sumShader, 0);

		unif1.Binding = 1;
		unif2.Binding = 0;
		_secondStepSumUniformSet = _rd.UniformSetCreate(new Godot.Collections.Array<RDUniform> { unif1, unif2 }, _sumShader, 0);

		// Convert positions to byte array
		byte[] positionsData = new byte[_positions.Length * 8]; // Vector2 = 2 floats = 8 bytes
		for (int i = 0; i < _positions.Length; i++)
		{
			byte[] xBytes = BitConverter.GetBytes(_positions[i].X);
			byte[] yBytes = BitConverter.GetBytes(_positions[i].Y);
			Array.Copy(xBytes, 0, positionsData, i * 8, 4);
			Array.Copy(yBytes, 0, positionsData, i * 8 + 4, 4);
		}

		_positionsBuffer = _rd.StorageBufferCreate((uint)positionsData.Length, positionsData);
		_predicatedPositionsBuffer = _rd.StorageBufferCreate((uint)positionsData.Length);
		_velocityBuffer = _rd.StorageBufferCreate((uint)positionsData.Length);
		_densityBuffer = _rd.StorageBufferCreate((uint)(_intSize * _positions.Length));
		_hashCountBuffer = _rd.StorageBufferCreate((uint)(_intSize * _hashOversizing * _positions.Length));
		_hashIndexesBuffer = _rd.StorageBufferCreate((uint)(_intSize * _positions.Length));
		_forceBuffer = _rd.StorageBufferCreate((uint)positionsData.Length);

		// Create output texture
		var outputImage = Image.Create(_imgSizeX, _imgSizeY, false, Image.Format.Rgbaf);
		var imageTexture = ImageTexture.CreateFromImage(outputImage);
		_textureRect.Texture = imageTexture;
		_outputTex = _rd.TextureCreate(_fmt, _view, new Godot.Collections.Array<byte[]> { outputImage.GetData() });

		// Create uniforms
		_positionsUniform = GetBufferUniform(0, _positionsBuffer);
		_predicatedPositionsUniform = GetBufferUniform(1, _predicatedPositionsBuffer);
		_velocityUniform = GetBufferUniform(2, _velocityBuffer);
		_densityUniform = GetBufferUniform(3, _densityBuffer);
		_hashCountUniform = GetBufferUniform(4, _hashCountBuffer);
		_prefSumHashCountUniform = GetBufferUniform(5, _prefSumHashCountBuffer);
		_hashIndexesUniform = GetBufferUniform(6, _hashIndexesBuffer);
		_prefSumHashCountUniform2 = GetBufferUniform(7, _prefSumHashCountBuffer2);
		_forceBufferUniform = GetBufferUniform(9, _forceBuffer);

		_outputTexUniform = new RDUniform();
		_outputTexUniform.UniformType = RenderingDevice.UniformType.Image;
		_outputTexUniform.Binding = 8;
		_outputTexUniform.AddId(_outputTex);

		_uniformSet = _rd.UniformSetCreate(new Godot.Collections.Array<RDUniform> {
			_positionsUniform,
			_predicatedPositionsUniform,
			_velocityUniform,
			_densityUniform,
			_hashCountUniform,
			_prefSumHashCountUniform,
			_hashIndexesUniform,
			_outputTexUniform,
			_prefSumHashCountUniform2,
			_forceBufferUniform
		}, _shader, 0);
	}

	// Signal handlers
	private void _on_pause_button_pressed()
	{
		GD.Print("aagag");
		GetTree().Paused = !GetTree().Paused;
	}

	private void _on_smoothing_spin_box_value_changed(double value)
	{
		_smoothingRadius = (float)value;
	}

	private void _on_density_spin_box_value_changed(double value)
	{
		_defaultDensity = (float)value / 1000.0f;
	}

	private void _on_next_step_button_pressed()
	{
		if (GetTree().Paused)
		{
			_Process(0.1);
		}
	}

	private void _on_spin_box_2_value_changed(double value)
	{
		_pressureMultiply = (float)value;
	}

	private void _on_gravity_spin_box_value_changed(double value)
	{
		_gravity = (float)value;
	}

	private void _on_mass_spin_box_value_changed(double value)
	{
		_mass = (float)value;
	}

	private void _on_viscosity_spin_box_value_changed(double value)
	{
		_viscosityMultiplier = (float)value;
	}
}
