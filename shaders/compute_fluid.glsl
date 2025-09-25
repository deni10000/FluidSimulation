#[compute]
#version 450

layout(push_constant, std430) uniform Params {
	int run_mode;
    float radius;
    float smoothing_radius;
    float gravity;
    float default_density;
    float pressure_multiply;
    float damping;
    uint  count;
    uint  hash_size;
    float  mass;
    float delta;
    uint screen_size_x;
    uint screen_size_y;
    float viscosity_multiplier;
    float mouse_x;
    float mouse_y;
} pc;

layout(set = 0, binding = 0, std430) restrict buffer ParticleBuffer {
    vec2 positions[];
}  particleBuf;

layout(set = 0, binding = 1, std430) restrict buffer PredictedBuffer {
    vec2 pred_positions[];
}  predictedBuf;

layout(set = 0, binding = 2, std430) restrict buffer VelocityBuffer {
    vec2 velocity[];
}  velocityBuf;

layout(set = 0, binding = 3, std430) restrict buffer DensityBuffer {
    float density[];
} densityBuf;

layout(set = 0, binding = 4, std430) restrict buffer HashCountBuffer {
    uint hash_count[];
}  hashCountBuf;

layout(set = 0, binding = 5, std430) restrict buffer PrefSumHashBuffer {
    uint pref_sum_hash_count[];
}  prefSumHashBuf;

layout(set = 0, binding = 7, std430) restrict buffer PrefSumHashBuffer2 {
    uint pref_sum_hash_count[];
}  prefSumHashBuf2;

layout(set = 0, binding = 6, std430) restrict buffer HashIndexBuffer {
    uint hash_indexes[];
} hashIndexBuf;

layout(set = 0, binding = 9, std430) restrict buffer ForceBuffer {
    vec2 forces[];
};

layout(set = 0, binding = 8, rgba8) uniform restrict writeonly image2D OUTPUT_TEXTURE;

void clear_circle(uint i) {
    vec2 center = particleBuf.positions[i];
    float radius = pc.radius;

	int min_x = int(floor(center.x - radius));
	int max_x = int(ceil(center.x + radius));
	int min_y = int(floor(center.y - radius));
	int max_y = int(ceil(center.y + radius));

    vec4 color = vec4(0, 0, 0, 0);
	for (int x = min_x; x <= max_x; x++) {
		for (int y = min_y; y <= max_y; y++) {
            float dx = x - center.x;
            float dy = y - center.y;
			if (dx * dx + dy * dy <= radius * radius) {
				imageStore(OUTPUT_TEXTURE, ivec2(x, y), color);
			}
		}
	}
}

void draw_circle(uint i) {
    vec2 center = particleBuf.positions[i];
    float radius = pc.radius;

	int min_x = int(floor(center.x - radius));
	int max_x = int(ceil(center.x + radius));
	int min_y = int(floor(center.y - radius));
	int max_y = int(ceil(center.y + radius));
    // vec4 color = vec4(0, 0, 1, 1);
    float dens = densityBuf.density[i];
    vec4 color;
    float ratio;
    if (dens >= pc.default_density) {
        ratio = pc.default_density / dens;
        color = vec4(ratio, ratio, 1, 1); 
        // color = vec4(1 - ratio, 1 - ratio, 1, 1);
    } else {
        ratio = dens / pc.default_density;
        color = vec4(1, 1, ratio, 1);
        // color = vec4(1 - ratio, 1 - ratio, ratio, 1);
    }
	for (int x = min_x; x <= max_x; x++) {
		for (int y = min_y; y <= max_y; y++) {
            float dx = x - center.x;
            float dy = y - center.y;
			if (dx * dx + dy * dy <= radius * radius) {
				imageStore(OUTPUT_TEXTURE, ivec2(x, y), color);
			}
		}
	}
}


float pow3_smoothing(float h, float d) {
    if (d >= h) return 0.0;
    float v = (3.14159265359 * pow(h, 4.0)) / 6.0;
    return pow(h - d, 2.0) / v;
}

float pow2_smoothing(float h, float d) {
    if (d >= h) return 0.0;
    float scale = 12.0 / (pow(h, 4.0) * 3.14159265359);
    return (d - h) * scale;
}

float density_to_pressure(float rho) {
   // return (rho - pc.default_density) * pc.pressure_multiply;
   return pc.pressure_multiply * (pow(rho / pc.default_density, 7.0) - 1 );
}

float shared_pressure(float rho1, float rho2) {
    return (density_to_pressure(rho1) + density_to_pressure(rho2)) * 0.5;
}

uvec2 coord_to_cell_pos(vec2 pos) {
    ivec2 ip = ivec2(floor(pos / pc.smoothing_radius));
    return uvec2(ip);
}

uint cell_hash(uvec2 cell) {
    uint a = uint(abs(int(cell.x))) * 15823u;
    uint b = uint(abs(int(cell.y))) * 9737333u;
    return a + b;
}



uint get_cell_count(uint h) {
    return hashCountBuf.hash_count[h];
}

void clear_hash_buffer(uint i) {
    hashCountBuf.hash_count[i] = 0;
    prefSumHashBuf.pref_sum_hash_count[i] = 0;
    prefSumHashBuf2.pref_sum_hash_count[i] = 0;
}

void fill_hash_count_buffer(uint i) {
    uint h = cell_hash(coord_to_cell_pos(predictedBuf.pred_positions[i])) % pc.hash_size;
    atomicAdd(hashCountBuf.hash_count[h], 1u);
    atomicAdd(prefSumHashBuf.pref_sum_hash_count[h], 1u);
}

void fill_hash_indexes(uint i) {
    uint h = cell_hash(coord_to_cell_pos(predictedBuf.pred_positions[i])) % pc.hash_size;
    uint val = atomicAdd(prefSumHashBuf2.pref_sum_hash_count[h], -1u);
    hashIndexBuf.hash_indexes[val - 1u] = i;
}

void compute_density(uint j) {
    vec2 pos_j = predictedBuf.pred_positions[j];
    float rho = 0.0;
    uvec2 base = coord_to_cell_pos(pos_j);
    for (int dx = -1; dx <= 1; ++dx) {
        for (int dy = -1; dy <= 1; ++dy) {
            uvec2 cell = base + uvec2(dx, dy);
            uint h = cell_hash(cell) % pc.hash_size;
            uint start = prefSumHashBuf.pref_sum_hash_count[h] - 1;
            uint cnt   = get_cell_count(h);
            for (uint k = 0u; k < cnt; ++k) {
                uint i = hashIndexBuf.hash_indexes[start - k];
                float d = length(predictedBuf.pred_positions[i] - pos_j);
                rho += pow3_smoothing(pc.smoothing_radius, d) * pc.mass;
            }
        }
    }
    densityBuf.density[j] = rho;
}

// vec2 add_viscosity_force(uint j) {
//     vec2 force = vec2(0, 0);
//     vec2 pos_j = predictedBuf.pred_positions[j];
//     uvec2 base = coord_to_cell_pos(particleBuf.positions[j]);

//     for (int dx = -1; dx <= 1; ++dx) {
//         for (int dy = -1; dy <= 1; ++dy) {
//             uvec2 cell = base + uvec2(dx, dy);
//             uint h = cell_hash(cell) % pc.hash_size;
//             uint start = prefSumHashBuf.pref_sum_hash_count[h] - 1;
//             uint cnt   = get_cell_count(h);
//             for (uint k = 0u; k < cnt; ++k) {
//                 uint i = hashIndexBuf.hash_indexes[start - k];
//                 float d = length(predictedBuf.pred_positions[i] - pos_j);
//                 rho += pow3_smoothing(pc.smoothing_radius, d) * pc.mass;
//             }
//         }
//     }
//     densityBuf.density[j] = rho;
// } 

void compute_force(uint j) {
    vec2 pos_j = predictedBuf.pred_positions[j];
    float rho_j = densityBuf.density[j];
    float Pj    = density_to_pressure(rho_j);
    vec2 force = vec2(0.0);
    uvec2 base = coord_to_cell_pos(pos_j);
    for (int dx = -1; dx <= 1; ++dx) {
        for (int dy = -1; dy <= 1; ++dy) {
            uvec2 cell = base + uvec2(dx, dy);
            uint h = cell_hash(cell) % pc.hash_size;
            uint start = prefSumHashBuf.pref_sum_hash_count[h] - 1;
            uint cnt   = get_cell_count(h);
            for (uint k = 0u; k < cnt; ++k) {
                uint i = hashIndexBuf.hash_indexes[start - k];
                if (i == j) continue;
                float rho_i = densityBuf.density[i];
                vec2 rij = predictedBuf.pred_positions[i] - pos_j;
                float d = length(rij);
                // if (d == 0) continue;
                float slope = pow2_smoothing(pc.smoothing_radius, d);
                vec2 dir = (d > 0.0) ? (rij / d) : vec2(1.0, 0.0);
                float Pi = density_to_pressure(rho_i);
                float Pavg = (Pi + Pj) * 0.5;

                vec2 viscosity_force = (velocityBuf.velocity[i] - velocityBuf.velocity[j]) * pow3_smoothing(pc.smoothing_radius, d);

                //force += Pavg * dir * slope * pc.mass / rho_i;
                force += rho_j * pc.mass * (Pj / (rho_j * rho_j) + Pi / (rho_i * rho_i)) * dir * slope;
                force += viscosity_force * pc.viscosity_multiplier;
            }
        }
    }
    forces[j] = force;
}

void integrate(uint id, float delta) {
    vec2 pos = particleBuf.positions[id];
    velocityBuf.velocity[id] += vec2(0.0, pc.gravity) * delta;
    predictedBuf.pred_positions[id] = pos + velocityBuf.velocity[id] / 120.0;
}

void correct(uint id, float delta) {
    vec2 pos = particleBuf.positions[id];
    vec2 vel = velocityBuf.velocity[id];
    vec2 mouse_pos = vec2(pc.mouse_x, pc.mouse_y);
    vec2 dir = pos - mouse_pos;
    float d = length(dir);
    vec2 F   = forces[id] + (dir / d) * pow3_smoothing(200, d) * pc.mass * 200000;
    vel += (F / densityBuf.density[id]) * delta;
    pos += vel * delta;
    float right = pc.screen_size_x - pc.radius;
    float down = pc.screen_size_y - pc.radius;
    // boundary
    if (pos.x < pc.radius)      { pos.x = pc.radius; vel.x *= -pc.damping; }
    if (pos.y < pc.radius)      { pos.y = pc.radius; vel.y *= -pc.damping; }
    if (pos.x > right)          { pos.x = right; vel.x *= -pc.damping; }
    if (pos.y > down)          { pos.y = down; vel.y *= -pc.damping; }
    particleBuf.positions[id] = pos;
    velocityBuf.velocity[id]  = vel;
}

layout(local_size_x = 256, local_size_y = 1, local_size_z = 1) in;
void main() {
	uint i = gl_GlobalInvocationID.x;
    switch(pc.run_mode) {
        case -1:
            if (i < pc.hash_size) {
                clear_circle(i);
            }
        case 0:
            if (i < pc.hash_size) {
                clear_hash_buffer(i);
            }
            break;
        case 1:
            if (i < pc.count) {
                fill_hash_count_buffer(i);
            }
            break;
        case 2:
            if (i < pc.count) {
                fill_hash_indexes(i);
            }
            break;
        case 3:
            if (i < pc.count) {
                integrate(i, pc.delta);
            }
            break;
        case 4:
            if (i < pc.count) {
                compute_density(i);
            }
            break;
        case 5:
            if (i < pc.count) {
                compute_force(i);
            }
            break;
        case 6:
             if (i < pc.count) {
                correct(i, pc.delta);
                draw_circle(i);
            }
            break;
    }
}