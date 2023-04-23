float kernel(const float x, const float B, const float C)
{
	float dx = abs(x);

	if (dx < 1.0) {
		float P1 = 2.0 - 3.0 / 2.0 * B - C;
		float P2 = -3.0 + 2.0 * B + C;
		float P3 = 1.0 - 1.0 / 3.0 * B;

		return P1 * cb(dx) + P2 * sq(dx) + P3;
	} else if ((dx >= 1.0) && (dx < 2.0)) {
		float P1 = -1.0 / 6.0 * B - C;
		float P2 = B + 5.0 * C;
		float P3 = -2.0 * B - 8.0 * C;
		float P4 = 4.0 / 3.0 * B + 4.0 * C;

		return P1 * cb(dx) + P2 * sq(dx) + P3 * dx + P4;
	} else
		return 0.0;
}

vec4 kernel4(const float x, const float B, const float C)
{
	return vec4(kernel(x - 2.0, B, C),
	            kernel(x - 1.0, B, C),
	            kernel(x, B, C),
	            kernel(x + 1.0, B, C));
}
