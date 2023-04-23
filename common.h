const float PI = 3.14159265359;
const vec3 BLACK = vec3(0.0, 0.0, 0.0);
const vec3 WHITE = vec3(1.0, 1.0, 1.0);

float sq(const float x)
{
	return x * x;
}

float cb(const float x)
{
	return x * x * x;
}

float sdr_linear(const float x)
{
	return x < 0.081 ? x / 4.5 : pow((x + 0.099) / 1.099, 1.0 / 0.45);
}

vec3 sdr_linear(const vec3 x)
{
	return vec3(sdr_linear(x.r), sdr_linear(x.g), sdr_linear(x.b));
}

float sdr_gamma(const float x)
{
	return x < 0.018 ? 4.5 * x : 1.099 * pow(x, 0.45) - 0.099;
}

vec3 sdr_gamma(const vec3 x)
{
	return vec3(sdr_gamma(x.r), sdr_gamma(x.g), sdr_gamma(x.b));
}

float srgb_linear(const float x)
{
	return x <= 0.04045 ? x / 12.92 : pow((x + 0.055) / 1.055, 2.4);
}

vec3 srgb_linear(const vec3 x)
{
	return vec3(srgb_linear(x.r), srgb_linear(x.g), srgb_linear(x.b));
}

float srgb_gamma(const float x)
{
	return x <= 0.0031308 ? 12.92 * x : 1.055 * pow(x, 1.0 / 2.4) - 0.055;
}

vec3 srgb_gamma(const vec3 x)
{
	return vec3(srgb_gamma(x.r), srgb_gamma(x.g), srgb_gamma(x.b));
}
