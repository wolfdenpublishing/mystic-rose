shader_type canvas_item;

uniform float size : hint_range(0.0, 1.0);
uniform float edge_softness = 0.0;
uniform vec4 color : source_color;

void fragment() 
{
	float radius = size * 0.5;
	float d = distance(UV, vec2(0.5));
	float circle = smoothstep(d - edge_softness, d, radius - edge_softness);
	COLOR = vec4(color.rgb, circle);
}