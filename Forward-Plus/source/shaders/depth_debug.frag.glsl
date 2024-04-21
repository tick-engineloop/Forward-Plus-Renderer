#version 330 core

uniform float near;	// near clipping plane in camera space
uniform float far;	// far clipping plane in camera space

out vec4 fragColor;

// Need to linearize the depth because we are using the projection
float LinearizeDepth(float depth) {
	// ==============================================================
	// back to NDC from screen space
	// ==============================================================
	// Viewport transform:
	//
	//			 farVal - nearVal            farVal + nearVal
	// Z_wnd = ————————————————————Z_ndc + ————————————————————
	//                  2                           2
	//
	// 当 glDepthRange 函数指定 farVal = 1.0，nearVal = 0.0 时（默认值，这指定的是屏幕空间深度值范围，与摄像机空间的 far 和 near 不同）：
	//
	//           Z_ndc + 1
	// Z_wnd = ——————————————
	//               2
	// 那么：
	//
	// Z_ndc = 2 * Z_wnd - 1
	// ==============================================================
	float z = depth * 2.0 - 1.0;

	// back to camera space from NDC
	return (2.0 * near * far) / (far + near - z * (far - near));
}

void main() {
	// 片段在摄像机空间内线性化的深度值处于 near 与 far 之间，需要归一化
	float depth = (LinearizeDepth(gl_FragCoord.z) - near) / (far - near);
	
	fragColor = vec4(vec3(depth), 1.0f);
}