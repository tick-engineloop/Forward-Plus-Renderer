#version 430

struct PointLight {
	vec4 color;
	vec4 position;
	vec4 paddingAndRadius;
};

struct VisibleIndex {
	int index;
};

// Shader storage buffer objects
layout(std430, binding = 0) readonly buffer LightBuffer {
	PointLight data[];
} lightBuffer;

layout(std430, binding = 1) writeonly buffer VisibleLightIndicesBuffer {
	VisibleIndex data[];
} visibleLightIndicesBuffer;

// Uniforms
uniform sampler2D depthMap;
uniform mat4 view;
uniform mat4 projection;
uniform ivec2 screenSize;
uniform int lightCount;

// Shared values between all the threads in the group
shared uint minDepthInt;
shared uint maxDepthInt;
shared uint visibleLightCount;
shared vec4 frustumPlanes[6];

// Shared local storage for visible indices, will be written out to the global buffer at the end
shared int visibleLightIndices[1024];
shared mat4 viewProjection;

// Took some light culling guidance from Dice's deferred renderer
// http://www.dice.se/news/directx-11-rendering-battlefield-3/

#define TILE_SIZE 16
layout(local_size_x = TILE_SIZE, local_size_y = TILE_SIZE, local_size_z = 1) in;

void main() {
	ivec2 location = ivec2(gl_GlobalInvocationID.xy);
	ivec2 itemID = ivec2(gl_LocalInvocationID.xy);
	ivec2 tileID = ivec2(gl_WorkGroupID.xy);
	ivec2 tileNumber = ivec2(gl_NumWorkGroups.xy);
	uint index = tileID.y * tileNumber.x + tileID.x;	// 求当前计算着色器调用所在工作组的一维索引

	// Initialize shared global values for depth and light count
	if (gl_LocalInvocationIndex == 0) {
		minDepthInt = 0xFFFFFFFF;
		maxDepthInt = 0;
		visibleLightCount = 0;
		viewProjection = projection * view;
	}

	barrier();

	// Step 1: Calculate the minimum and maximum depth values (from the depth buffer) for this group's tile
	float maxDepth, minDepth;
	vec2 text = vec2(location) / screenSize;	// 将 location 转换到 [0, 1] 范围内
	float depth = texture(depthMap, text).r;	// 从名为 depthMap 的纹理中采样，并获取其红色分量。这通常用于从深度纹理中获取深度值。
	// Linearize the depth value from depth buffer (must do this because we created it using projection)
	depth = (0.5 * projection[3][2]) / (depth + 0.5 * projection[2][2] - 0.5);	// glm 矩阵是列主序，并且因为索引以 0 为起始， projection[3][2] 表示的是第 4 列第 3 行，projection[2][2] 表示的是第 3 列第 3 行

	// Convert depth to uint so we can do atomic min and max comparisons between the threads
	// ====================================================================================================
	// * genUType floatBitsToUint(genType x);
	// | ---> floatBitsToUint 将浮点参数编码为 uint。浮点位级表示将被保留。
	// ====================================================================================================
	// * uint atomicMin(inout uint mem, uint data);
	// | ---> atomicMin 将 data 与 mem 中的内容进行原子比较，然后将最小值写入 mem，并返回比较前 mem 中的原始内容。
	// ====================================================================================================
	// * uint atomicMax(inout uint mem, uint data);
	// | ---> atomicMax 将 data 与 mem 中的内容进行原子比较，然后将最大值写入 mem，并返回比较前 mem 中的原始内容。
	// ====================================================================================================
	uint depthInt = floatBitsToUint(depth);
	atomicMin(minDepthInt, depthInt);
	atomicMax(maxDepthInt, depthInt);

	barrier();

	// Step 2: One thread should calculate the frustum planes to be used for this tile
	if (gl_LocalInvocationIndex == 0) {
		// Convert the min and max across the entire tile back to float
		minDepth = uintBitsToFloat(minDepthInt);
		maxDepth = uintBitsToFloat(maxDepthInt);

		// Steps based on tile sale
		vec2 negativeStep = (2.0 * vec2(tileID)) / vec2(tileNumber);
		vec2 positiveStep = (2.0 * vec2(tileID + ivec2(1, 1))) / vec2(tileNumber);

		// Set up starting values for planes using steps and min and max z values
		frustumPlanes[0] = vec4(1.0, 0.0, 0.0, 1.0 - negativeStep.x); 	// Left，定义左平面，平面方程为 x + (1.0 - negativeStep.x) = 0
		frustumPlanes[1] = vec4(-1.0, 0.0, 0.0, -1.0 + positiveStep.x); // Right，定义右平面，平面方程为 x + (1.0 - positiveStep.x) = 0
		frustumPlanes[2] = vec4(0.0, 1.0, 0.0, 1.0 - negativeStep.y); 	// Bottom，定义下平面，平面方程为 y + (1.0 - negativeStep.y) = 0
		frustumPlanes[3] = vec4(0.0, -1.0, 0.0, -1.0 + positiveStep.y); // Top，定义上平面，平面方程为 y + (1.0 - positiveStep.y) = 0
		frustumPlanes[4] = vec4(0.0, 0.0, -1.0, -minDepth); 			// Near，定义近平面， 平面方程为 z + minDepth = 0
		frustumPlanes[5] = vec4(0.0, 0.0, 1.0, maxDepth); 				// Far，定义远平面，平面方程为 z + maxDepth = 0

		// Transform the first four planes
		for (uint i = 0; i < 4; i++) {
			frustumPlanes[i] *= viewProjection;
			frustumPlanes[i] /= length(frustumPlanes[i].xyz);
		}

		// Transform the depth planes
		frustumPlanes[4] *= view;
		frustumPlanes[4] /= length(frustumPlanes[4].xyz);
		frustumPlanes[5] *= view;
		frustumPlanes[5] /= length(frustumPlanes[5].xyz);
	}

	barrier();

	// Step 3: Cull lights.
	// Parallelize the threads against the lights now.
	// Can handle 256 simultaniously. Anymore lights than that and additional passes are performed
	uint threadCount = TILE_SIZE * TILE_SIZE;
	uint passCount = (lightCount + threadCount - 1) / threadCount;
	for (uint i = 0; i < passCount; i++) {
		// Get the lightIndex to test for this thread / pass. If the index is >= light count, then this thread can stop testing lights
		uint lightIndex = i * threadCount + gl_LocalInvocationIndex;
		if (lightIndex >= lightCount) {
			break;
		}

		vec4 position = lightBuffer.data[lightIndex].position;
		float radius = lightBuffer.data[lightIndex].paddingAndRadius.w;

		// We check if the light exists in our frustum
		float distance = 0.0;
		for (uint j = 0; j < 6; j++) {
			distance = dot(position, frustumPlanes[j]) + radius;

			// If one of the tests fails, then there is no intersection
			if (distance <= 0.0) {
				break;
			}
		}

		// If greater than zero, then it is a visible light
		if (distance > 0.0) {
			// Add index to the shared array of visible indices
			uint offset = atomicAdd(visibleLightCount, 1);
			visibleLightIndices[offset] = int(lightIndex);
		}
	}

	barrier();

	// One thread should fill the global light buffer
	if (gl_LocalInvocationIndex == 0) {
		uint offset = index * 1024; // Determine bosition in global buffer
		for (uint i = 0; i < visibleLightCount; i++) {
			visibleLightIndicesBuffer.data[offset + i].index = visibleLightIndices[i];
		}

		if (visibleLightCount != 1024) {
			// Unless we have totally filled the entire array, mark it's end with -1
			// Final shader step will use this to determine where to stop (without having to pass the light count)
			visibleLightIndicesBuffer.data[offset + visibleLightCount].index = -1;
		}
	}
}
