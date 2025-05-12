shader_type canvas_item;

uniform int particle_count;
uniform float radius;
uniform float target_density;
uniform vec2 positions_tex[1000]; 
uniform vec2 texture_size;
uniform float mass;

float smoothing_kernel(float dst) {
    if (dst >= radius) return 0.0;
	float v = (PI * pow(radius, 4)) / 6.0;
    return pow(radius - dst, 2) / v;
}

void fragment() {
    vec2 pixel_pos = SCREEN_UV * texture_size;
    float total_density = 0.0;
	
    for (int i = 0; i < particle_count; i++) {
        //float u = (float(i) + 0.5) / float(particle_count);
        //vec2 pos = texelFetch(positions_tex, ivec2(int(u * texture_size.x), 0), 0).xy;
		vec2 pos = positions_tex[i];

        float kernel = smoothing_kernel(length(pixel_pos - pos));
        total_density += kernel * mass;
    }
    float diff = total_density - target_density;
    float fade = clamp(abs(diff) / target_density, 0.0, 1.0);

    // Gradient coloring
    vec3 color;
    if (diff < 0.0) {
        // Less dense → blue to white
        color = mix(vec3(0.0, 0.5, 1.0), vec3(1.0), 1.0 - fade);
    } else {
        // More dense → white to red
        color = mix(vec3(1.0), vec3(1.0, 0.0, 0.0), fade);
    }

    COLOR = vec4(color, 1.0);
}
