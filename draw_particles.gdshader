shader_type canvas_item;

uniform int particle_count;
uniform float radius;
uniform float target_density;
uniform vec2 positions_tex[1000];
uniform vec2 texture_size;
uniform float mass;


void fragment() {
    vec2 pixel_pos = SCREEN_UV * texture_size;
    float total_density = 0.0;

    for (int i = 0; i < particle_count; i++) {
        //float u = (float(i) + 0.5) / float(particle_count);
        //vec2 pos = texelFetch(positions_tex, ivec2(int(u * texture_size.x), 0), 0).xy;
		vec2 pos = positions_tex[i];
        if (length(pos - pixel_pos) < 5.0) {
			COLOR = vec4(0, 0, 1, 1);
		}
    }
}
