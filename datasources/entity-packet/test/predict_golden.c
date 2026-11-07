/*
 * The emitted prediction kernel, against the Lean spec's own numbers.
 *
 *   cc -std=c11 -Wall -Wextra -Werror -I build test/predict_golden.c -o build/predict_golden
 *   build/predict_golden build/predict_golden.csv
 *
 * Each row of the CSV is one (vpp, vp, vf, vt, lag, vmax) the spec evaluated; the C kernel must
 * return the same displacement in micrometres, bit for bit.
 *
 * SPDX-License-Identifier: MIT
 */

#include "entity_predict.h"

#include <stdio.h>

int main(int argc, char **argv)
{
	if (argc != 2) {
		fprintf(stderr, "usage: predict_golden <predict_golden.csv>\n");
		return 2;
	}
	FILE *f = fopen(argv[1], "r");
	if (!f) {
		perror(argv[1]);
		return 2;
	}
	char line[256];
	int rows = 0, bad = 0;
	if (!fgets(line, sizeof line, f))
		return 2;
	while (fgets(line, sizeof line, f)) {
		long long a, b, c, d, l, vm, want;
		if (sscanf(line, "%lld,%lld,%lld,%lld,%lld,%lld,%lld", &a, &b, &c, &d, &l, &vm, &want) != 7) {
			bad++;
			continue;
		}
		rows++;
		long long got = xr_predict_disp_um((int32_t)a, (int32_t)b, (int32_t)c, (int32_t)d, (int32_t)l, vm);
		if (got != want) {
			if (bad < 5)
				printf("row %d: got %lld um, spec %lld um (lag %lld ticks, vmax %lld um per tick)\n", rows, got, want, l, vm);
			bad++;
		}
	}
	fclose(f);
	printf("predict golden: %d rows, %d mismatches\n", rows, bad);
	return bad ? 1 : 0;
}
