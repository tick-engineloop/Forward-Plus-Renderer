#version 330 core

uniform float near;
uniform float far;

out vec4 fragColor;

// Need to linearize the depth because we are using the projection
float LinearizeDepth(float depth) {
	// ==============================================================
	// back to NDC
	// ==============================================================
	// Viewport transform:
	//
	//			 farVal - nearVal            farVal + nearVal
	// Z_wnd = ————————————————————Z_ndc + ————————————————————
	//                  2                           2
	//
	// 当 farVal = 1.0，nearVal = 0.0 时：
	//
	//           Z_ndc + 1
	// Z_wnd = ——————————————
	//               2
	// 那么：
	//
	// Z_ndc = 2 * Z_wnd - 1
	// ==============================================================
	float z = depth * 2.0 - 1.0;

	return (2.0 * near * far) / (far + near - z * (far - near));
}

void main() {
	float depth = LinearizeDepth(gl_FragCoord.z) / far;
	fragColor = vec4(vec3(depth), 1.0f);
}