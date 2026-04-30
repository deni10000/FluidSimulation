#[compute]
#version 450
layout(local_size_x = 512, local_size_y = 1, local_size_z = 1) in;

layout(set = 0, binding = 0, std430) restrict buffer InputBuffer {
    uint in_data[];
};

layout(set = 0, binding = 1, std430) restrict buffer OutputBuffer {
    uint out_data[];
};

layout(set = 0, binding = 2, std430) restrict buffer SquaredPrefSum {
    uint sq_data[];
};

layout(push_constant) uniform Params {
    uint count; 
    uint type;
} pc;

void main() {
    uint i = gl_GlobalInvocationID.x;
    if (i >= sq_data.length()) {
        return;
    }
    uint start = i * pc.count;
    uint end = min(start + pc.count, in_data.length());
    if (pc.type == 0) {
        out_data[start] = in_data[start];

        for(uint j = start + 1; j < end; j++) {
            out_data[j] = out_data[j - 1] + in_data[j];
        }

        end --;
        for(uint j = i + 1; j < sq_data.length();  j++) {
            atomicAdd(sq_data[j], out_data[end]);
        }
    } else {
        for(uint j = start; j < end; j++) {
            out_data[j] += sq_data[i];
            in_data[j] = out_data[j];
        }
        sq_data[i] = 0;
    }
}
