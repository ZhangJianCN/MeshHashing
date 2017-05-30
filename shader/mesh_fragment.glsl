#version 330 core

in vec3 normal_frag;
in vec3 position_frag;

out vec3 color;

void main() {
	float g = abs(dot(normal_frag, normalize(vec3(0, 2, 0) - position_frag)));
	color = g * vec3(0.88f, 0.72f, 0.62f); // Magic color
}