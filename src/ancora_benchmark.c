/*
 * ancora_benchmark.c
 *
 * Description
 * -----------
 * CORA-COMP benchmark driver for ancora. run_instance.sh parses the instance's
 * params JSON and passes the fields here as command-line arguments; this
 * program generates the random sets the catalog defines and performs the
 * requested operation `repetition` times. Exits 0 on success, nonzero on
 * failure (run_instance.sh maps that to the `finished`/`error` verdict).
 *
 * The benchmark measures the fast plain-double path, so this driver is built
 * in ANCORA_MODE_FAST.
 *
 * Operation -> ancora mapping (see the benchmark catalog and the toolkit
 * README):
 *   generateRandom -> ancora_interval_initRandom_uniform /
 *                     ancora_zonotope_initRandom_uniform
 *   randPoint      -> ancora_interval_randomPoints_uniform /
 *                     ancora_zonotope_randomPoints_standard
 *   supportFunc    -> ancora_interval_supportFunction /
 *                     ancora_zonotope_supportFunction
 *   matMul         -> ancora_interval_affine / ancora_zonotope_affine
 *                     (with the translation vector c = 0)
 *   minkSum        -> ancora_interval_minkowskiSum /
 *                     ancora_zonotope_minkowskiSum
 *   contains       -> ancora_interval_containsPoints /
 *                     ancora_zonotope_containsPoints
 * The batched variants (ancora_*_batched_*) are used when batch_size > 1.
 *
 * File Information
 * ----------------
 * Created:       2026-09-27
 * Last modified: 2026-09-27
 * Author(s):     ancora
 *
 * License
 * -------
 * SPDX-License-Identifier: MIT
 */

#include "ancora/ancora.h"

#include <math.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#if ANCORA_MODE != ANCORA_MODE_FAST
#error "ancora_benchmark.c targets ANCORA_MODE_FAST (the benchmark measures the fast plain-double path)."
#endif

/* ------------------------------------------------------------------ */
/* Helpers                                                             */
/* ------------------------------------------------------------------ */

static int fail(const char *msg)
{
    fprintf(stderr, "ancora_benchmark: %s\n", msg);
    return 1;
}

/* Initialize an interval of dimension n (bounds zeroed; overwritten later). */
static ancora_status init_interval_dim(ancora_interval *I, slong n)
{
    ancora_vec lo, hi;
    ANCORA_TRY(ancora_vec_init(&lo, n));
    ANCORA_TRY(ancora_vec_init(&hi, n));
    ANCORA_TRY(ancora_vec_zeros(&lo));
    ANCORA_TRY(ancora_vec_zeros(&hi));
    ANCORA_TRY(ancora_interval_init(I, &lo, &hi));
    ANCORA_TRY(ancora_vec_free(&lo));
    ANCORA_TRY(ancora_vec_free(&hi));
    return ANCORA_OK;
}

/* Initialize a zonotope of dimension n with m generators (zeroed). */
static ancora_status init_zonotope_dim(ancora_zonotope *Z, slong n, slong m)
{
    ancora_vec c;
    ancora_mat G;
    ANCORA_TRY(ancora_vec_init(&c, n));
    ANCORA_TRY(ancora_mat_init(&G, n, m));
    ANCORA_TRY(ancora_vec_zeros(&c));
    ANCORA_TRY(ancora_mat_zeros(&G));
    ANCORA_TRY(ancora_zonotope_init(Z, &c, &G));
    ANCORA_TRY(ancora_vec_free(&c));
    ANCORA_TRY(ancora_mat_free(&G));
    return ANCORA_OK;
}

/* Random unit direction vector of length n (uniform on the sphere). */
static ancora_status make_unit_direction(ancora_vec *d, slong n)
{
    ANCORA_TRY(ancora_vec_init(d, n));
    double norm2 = 0.0;
    for (slong i = 0; i < n; i++) {
        double g;
        ANCORA_TRY(ancora_random_gaussian(&g));
        ANCORA_TRY(ancora_vec_set(d, i, g));
        norm2 += g * g;
    }
    double norm = sqrt(norm2);
    if (norm > 0.0) {
        for (slong i = 0; i < n; i++) {
            double v;
            ANCORA_TRY(ancora_vec_get(d, i, &v));
            ANCORA_TRY(ancora_vec_set(d, i, v / norm));
        }
    }
    return ANCORA_OK;
}

/* n x n matrix with standard-normal entries (randn). */
static ancora_status make_random_matrix(ancora_mat *M, slong n)
{
    ANCORA_TRY(ancora_mat_init(M, n, n));
    for (slong i = 0; i < n; i++) {
        for (slong j = 0; j < n; j++) {
            double g;
            ANCORA_TRY(ancora_random_gaussian(&g));
            ANCORA_TRY(ancora_mat_set(M, i, j, g));
        }
    }
    return ANCORA_OK;
}

/* Zero vector of length n (the zero translation for matMul). */
static ancora_status make_zero_vector(ancora_vec *c, slong n)
{
    ANCORA_TRY(ancora_vec_init(c, n));
    return ancora_vec_zeros(c);
}

/* Batch allocation helpers. */
static ancora_interval *alloc_interval_batch(slong B, slong n)
{
    ancora_interval *batch = calloc((size_t)B, sizeof(ancora_interval));
    if (!batch) return NULL;
    for (slong b = 0; b < B; b++) {
        if (init_interval_dim(&batch[b], n) != ANCORA_OK) {
            for (slong k = 0; k < b; k++) ancora_interval_free(&batch[k]);
            free(batch);
            return NULL;
        }
    }
    return batch;
}
static void free_interval_batch(ancora_interval *batch, slong B)
{
    for (slong b = 0; b < B; b++) ancora_interval_free(&batch[b]);
    free(batch);
}

static ancora_zonotope *alloc_zonotope_batch(slong B, slong n, slong m)
{
    ancora_zonotope *batch = calloc((size_t)B, sizeof(ancora_zonotope));
    if (!batch) return NULL;
    for (slong b = 0; b < B; b++) {
        if (init_zonotope_dim(&batch[b], n, m) != ANCORA_OK) {
            for (slong k = 0; k < b; k++) ancora_zonotope_free(&batch[k]);
            free(batch);
            return NULL;
        }
    }
    return batch;
}
static void free_zonotope_batch(ancora_zonotope *batch, slong B)
{
    for (slong b = 0; b < B; b++) ancora_zonotope_free(&batch[b]);
    free(batch);
}

static ancora_mat *alloc_mat_batch(slong B, slong nrows, slong ncols)
{
    ancora_mat *batch = calloc((size_t)B, sizeof(ancora_mat));
    if (!batch) return NULL;
    for (slong b = 0; b < B; b++) {
        if (ancora_mat_init(&batch[b], nrows, ncols) != ANCORA_OK) {
            for (slong k = 0; k < b; k++) ancora_mat_free(&batch[k]);
            free(batch);
            return NULL;
        }
    }
    return batch;
}
static void free_mat_batch(ancora_mat *batch, slong B)
{
    for (slong b = 0; b < B; b++) ancora_mat_free(&batch[b]);
    free(batch);
}

static ancora_vec *alloc_vec_batch(slong B, slong n)
{
    ancora_vec *batch = calloc((size_t)B, sizeof(ancora_vec));
    if (!batch) return NULL;
    for (slong b = 0; b < B; b++) {
        if (ancora_vec_init(&batch[b], n) != ANCORA_OK) {
            for (slong k = 0; k < b; k++) ancora_vec_free(&batch[k]);
            free(batch);
            return NULL;
        }
    }
    return batch;
}
static void free_vec_batch(ancora_vec *batch, slong B)
{
    for (slong b = 0; b < B; b++) ancora_vec_free(&batch[b]);
    free(batch);
}

/* ------------------------------------------------------------------ */
/* Unbatched interval operations                                       */
/* ------------------------------------------------------------------ */

static int run_interval_unbatched(const char *operation, slong n, slong points,
                                  slong repetition)
{
    ancora_interval I;
    ANCORA_TRY(init_interval_dim(&I, n));

    if (strcmp(operation, "generateRandom") == 0) {
        for (slong r = 0; r < repetition; r++) {
            ANCORA_TRY(ancora_interval_initRandom_uniform(&I));
        }
    }
    else if (strcmp(operation, "randPoint") == 0) {
        ancora_mat P;
        ANCORA_TRY(ancora_mat_init(&P, n, points));
        for (slong r = 0; r < repetition; r++) {
            ANCORA_TRY(ancora_interval_randomPoints_uniform(&P, &I, points));
        }
        ANCORA_TRY(ancora_mat_free(&P));
    }
    else if (strcmp(operation, "supportFunc") == 0) {
        ancora_vec d;
        double res;
        ANCORA_TRY(make_unit_direction(&d, n));
        for (slong r = 0; r < repetition; r++) {
            ANCORA_TRY(ancora_interval_supportFunction(&res, &I, &d));
        }
        ANCORA_TRY(ancora_vec_free(&d));
    }
    else if (strcmp(operation, "matMul") == 0) {
        ancora_mat M;
        ancora_interval res;
        ANCORA_TRY(make_random_matrix(&M, n));
        ANCORA_TRY(init_interval_dim(&res, n));
        for (slong r = 0; r < repetition; r++) {
            ANCORA_TRY(ancora_interval_matMul(&res, &M, &I));
        }
        ANCORA_TRY(ancora_mat_free(&M));
        ANCORA_TRY(ancora_interval_free(&res));
    }
    else if (strcmp(operation, "minkSum") == 0) {
        ancora_interval I2, res;
        ANCORA_TRY(init_interval_dim(&I2, n));
        ANCORA_TRY(init_interval_dim(&res, n));
        for (slong r = 0; r < repetition; r++) {
            ANCORA_TRY(ancora_interval_minkowskiSum(&res, &I, &I2));
        }
        ANCORA_TRY(ancora_interval_free(&I2));
        ANCORA_TRY(ancora_interval_free(&res));
    }
    else if (strcmp(operation, "contains") == 0) {
        ancora_mat P;
        ancora_truth contained;
        ANCORA_TRY(ancora_mat_init(&P, n, points));
        ANCORA_TRY(ancora_interval_randomPoints_uniform(&P, &I, points));
        for (slong r = 0; r < repetition; r++) {
            ANCORA_TRY(ancora_interval_containsPoints(&I, &P, &contained));
            if (!ancora_yes(contained)) {
                ANCORA_TRY(ancora_mat_free(&P));
                ANCORA_TRY(ancora_interval_free(&I));
                return fail("interval contains returned false (points not in set)");
            }
        }
        ANCORA_TRY(ancora_mat_free(&P));
    }
    else {
        ANCORA_TRY(ancora_interval_free(&I));
        return fail("unknown interval operation");
    }

    ANCORA_TRY(ancora_interval_free(&I));
    return 0;
}

/* ------------------------------------------------------------------ */
/* Batched interval operations                                         */
/* ------------------------------------------------------------------ */

static int run_interval_batched(const char *operation, slong n, slong points,
                                slong B, slong repetition)
{
    ancora_interval *batch = alloc_interval_batch(B, n);
    if (!batch) return fail("alloc interval batch");
    const ancora_interval **I_batch = malloc((size_t)B * sizeof(const ancora_interval *));
    if (!I_batch) { free_interval_batch(batch, B); return fail("alloc I_batch"); }
    for (slong b = 0; b < B; b++) I_batch[b] = &batch[b];

    int rc = 0;

    if (strcmp(operation, "generateRandom") == 0) {
        for (slong r = 0; r < repetition; r++) {
            for (slong b = 0; b < B; b++) {
                if (ancora_interval_initRandom_uniform(&batch[b]) != ANCORA_OK) {
                    rc = fail("interval batched generateRandom");
                    goto cleanup;
                }
            }
        }
    }
    else if (strcmp(operation, "randPoint") == 0) {
        ancora_mat *P = alloc_mat_batch(B, n, points);
        ancora_mat **P_batch = malloc((size_t)B * sizeof(ancora_mat *));
        if (!P || !P_batch) { rc = fail("alloc P batch"); goto cleanup; }
        for (slong b = 0; b < B; b++) P_batch[b] = &P[b];
        for (slong r = 0; r < repetition; r++) {
            if (ancora_interval_batched_randomPoints_uniform(P_batch, I_batch, B, points) != ANCORA_OK) {
                rc = fail("interval batched randPoint");
                free(P_batch); free_mat_batch(P, B);
                goto cleanup;
            }
        }
        free(P_batch);
        free_mat_batch(P, B);
    }
    else if (strcmp(operation, "supportFunc") == 0) {
        ancora_vec *d = alloc_vec_batch(B, n);
        const ancora_vec **d_batch = malloc((size_t)B * sizeof(const ancora_vec *));
        double *res = malloc((size_t)B * sizeof(double));
        if (!d || !d_batch || !res) { rc = fail("alloc d batch"); goto cleanup; }
        for (slong b = 0; b < B; b++) {
            d_batch[b] = &d[b];
            if (make_unit_direction(&d[b], n) != ANCORA_OK) { rc = fail("make direction"); goto cleanup; }
        }
        for (slong r = 0; r < repetition; r++) {
            if (ancora_interval_batched_supportFunction(res, I_batch, d_batch, B) != ANCORA_OK) {
                rc = fail("interval batched supportFunc");
                goto cleanup;
            }
        }
        free(res);
        free(d_batch);
        free_vec_batch(d, B);
    }
    else if (strcmp(operation, "matMul") == 0) {
        ancora_mat M;
        ancora_interval *res = alloc_interval_batch(B, n);
        ancora_interval **res_batch = malloc((size_t)B * sizeof(ancora_interval *));
        if (!res || !res_batch) { rc = fail("alloc res batch"); goto cleanup; }
        for (slong b = 0; b < B; b++) res_batch[b] = &res[b];
        if (make_random_matrix(&M, n) != ANCORA_OK) { rc = fail("make matrix"); goto cleanup; }
        for (slong r = 0; r < repetition; r++) {
            if (ancora_interval_batched_matMul(res_batch, &M, I_batch, B) != ANCORA_OK) {
                rc = fail("interval batched matMul");
                goto cleanup;
            }
        }
        ancora_mat_free(&M);
        free(res_batch);
        free_interval_batch(res, B);
    }
    else if (strcmp(operation, "minkSum") == 0) {
        ancora_interval *I2 = alloc_interval_batch(B, n);
        ancora_interval *res = alloc_interval_batch(B, n);
        const ancora_interval **I2_batch = malloc((size_t)B * sizeof(const ancora_interval *));
        ancora_interval **res_batch = malloc((size_t)B * sizeof(ancora_interval *));
        if (!I2 || !res || !I2_batch || !res_batch) { rc = fail("alloc minkSum batches"); goto cleanup; }
        for (slong b = 0; b < B; b++) { I2_batch[b] = &I2[b]; res_batch[b] = &res[b]; }
        for (slong r = 0; r < repetition; r++) {
            if (ancora_interval_batched_minkowskiSum(res_batch, I_batch, I2_batch, B) != ANCORA_OK) {
                rc = fail("interval batched minkSum");
                goto cleanup;
            }
        }
        free(res_batch);
        free(I2_batch);
        free_interval_batch(res, B);
        free_interval_batch(I2, B);
    }
    else if (strcmp(operation, "contains") == 0) {
        ancora_mat *P = alloc_mat_batch(B, n, points);
        const ancora_mat **P_batch = malloc((size_t)B * sizeof(const ancora_mat *));
        ancora_truth contained;
        if (!P || !P_batch) { rc = fail("alloc P batch"); goto cleanup; }
        for (slong b = 0; b < B; b++) {
            P_batch[b] = &P[b];
            if (ancora_interval_randomPoints_uniform(&P[b], &batch[b], points) != ANCORA_OK) {
                rc = fail("draw points");
                goto cleanup;
            }
        }
        for (slong r = 0; r < repetition; r++) {
            if (ancora_interval_batched_containsPoints(I_batch, P_batch, B, &contained) != ANCORA_OK) {
                rc = fail("interval batched contains");
                goto cleanup;
            }
            if (!ancora_yes(contained)) { rc = fail("interval batched contains returned false"); goto cleanup; }
        }
        free(P_batch);
        free_mat_batch(P, B);
    }
    else {
        rc = fail("unknown interval operation");
    }

cleanup:
    free(I_batch);
    free_interval_batch(batch, B);
    return rc;
}

/* ------------------------------------------------------------------ */
/* Unbatched zonotope operations                                       */
/* ------------------------------------------------------------------ */

static int run_zonotope_unbatched(const char *operation, slong n, slong m,
                                  slong points, slong repetition)
{
    ancora_zonotope Z;
    ANCORA_TRY(init_zonotope_dim(&Z, n, m));

    if (strcmp(operation, "generateRandom") == 0) {
        for (slong r = 0; r < repetition; r++) {
            ANCORA_TRY(ancora_zonotope_initRandom_uniform(&Z));
        }
    }
    else if (strcmp(operation, "randPoint") == 0) {
        ancora_mat P;
        ANCORA_TRY(ancora_mat_init(&P, n, points));
        for (slong r = 0; r < repetition; r++) {
            ANCORA_TRY(ancora_zonotope_randomPoints_standard(&P, &Z, points));
        }
        ANCORA_TRY(ancora_mat_free(&P));
    }
    else if (strcmp(operation, "supportFunc") == 0) {
        ancora_vec d;
        double res;
        ANCORA_TRY(make_unit_direction(&d, n));
        for (slong r = 0; r < repetition; r++) {
            ANCORA_TRY(ancora_zonotope_supportFunction(&res, &Z, &d));
        }
        ANCORA_TRY(ancora_vec_free(&d));
    }
    else if (strcmp(operation, "matMul") == 0) {
        ancora_mat M;
        ancora_zonotope res;
        ANCORA_TRY(make_random_matrix(&M, n));
        ANCORA_TRY(init_zonotope_dim(&res, n, m));
        for (slong r = 0; r < repetition; r++) {
            ANCORA_TRY(ancora_zonotope_matMul(&res, &M, &Z));
        }
        ANCORA_TRY(ancora_mat_free(&M));
        ANCORA_TRY(ancora_zonotope_free(&res));
    }
    else if (strcmp(operation, "minkSum") == 0) {
        ancora_zonotope Z2, res;
        ANCORA_TRY(init_zonotope_dim(&Z2, n, m));
        ANCORA_TRY(init_zonotope_dim(&res, n, 2 * m));
        for (slong r = 0; r < repetition; r++) {
            ANCORA_TRY(ancora_zonotope_minkowskiSum(&res, &Z, &Z2));
        }
        ANCORA_TRY(ancora_zonotope_free(&Z2));
        ANCORA_TRY(ancora_zonotope_free(&res));
    }
    else if (strcmp(operation, "contains") == 0) {
        ancora_mat P;
        ancora_truth contained;
        ANCORA_TRY(ancora_mat_init(&P, n, points));
        ANCORA_TRY(ancora_zonotope_randomPoints_standard(&P, &Z, points));
        for (slong r = 0; r < repetition; r++) {
            ANCORA_TRY(ancora_zonotope_containsPoints(&Z, &P, &contained));
            if (!ancora_yes(contained)) {
                ANCORA_TRY(ancora_mat_free(&P));
                ANCORA_TRY(ancora_zonotope_free(&Z));
                return fail("zonotope contains returned false (points not in set)");
            }
        }
        ANCORA_TRY(ancora_mat_free(&P));
    }
    else {
        ANCORA_TRY(ancora_zonotope_free(&Z));
        return fail("unknown zonotope operation");
    }

    ANCORA_TRY(ancora_zonotope_free(&Z));
    return 0;
}

/* ------------------------------------------------------------------ */
/* Batched zonotope operations                                         */
/* ------------------------------------------------------------------ */

static int run_zonotope_batched(const char *operation, slong n, slong m,
                                slong points, slong B, slong repetition)
{
    ancora_zonotope *batch = alloc_zonotope_batch(B, n, m);
    if (!batch) return fail("alloc zonotope batch");
    const ancora_zonotope **Z_batch = malloc((size_t)B * sizeof(const ancora_zonotope *));
    if (!Z_batch) { free_zonotope_batch(batch, B); return fail("alloc Z_batch"); }
    for (slong b = 0; b < B; b++) Z_batch[b] = &batch[b];

    int rc = 0;

    if (strcmp(operation, "generateRandom") == 0) {
        for (slong r = 0; r < repetition; r++) {
            for (slong b = 0; b < B; b++) {
                if (ancora_zonotope_initRandom_uniform(&batch[b]) != ANCORA_OK) {
                    rc = fail("zonotope batched generateRandom");
                    goto cleanup;
                }
            }
        }
    }
    else if (strcmp(operation, "randPoint") == 0) {
        ancora_mat *P = alloc_mat_batch(B, n, points);
        ancora_mat **P_batch = malloc((size_t)B * sizeof(ancora_mat *));
        if (!P || !P_batch) { rc = fail("alloc P batch"); goto cleanup; }
        for (slong b = 0; b < B; b++) P_batch[b] = &P[b];
        for (slong r = 0; r < repetition; r++) {
            if (ancora_zonotope_batched_randomPoints_standard(P_batch, Z_batch, B, points) != ANCORA_OK) {
                rc = fail("zonotope batched randPoint");
                free(P_batch); free_mat_batch(P, B);
                goto cleanup;
            }
        }
        free(P_batch);
        free_mat_batch(P, B);
    }
    else if (strcmp(operation, "supportFunc") == 0) {
        ancora_vec *d = alloc_vec_batch(B, n);
        const ancora_vec **d_batch = malloc((size_t)B * sizeof(const ancora_vec *));
        double *res = malloc((size_t)B * sizeof(double));
        if (!d || !d_batch || !res) { rc = fail("alloc d batch"); goto cleanup; }
        for (slong b = 0; b < B; b++) {
            d_batch[b] = &d[b];
            if (make_unit_direction(&d[b], n) != ANCORA_OK) { rc = fail("make direction"); goto cleanup; }
        }
        for (slong r = 0; r < repetition; r++) {
            if (ancora_zonotope_batched_supportFunction(res, Z_batch, d_batch, B) != ANCORA_OK) {
                rc = fail("zonotope batched supportFunc");
                goto cleanup;
            }
        }
        free(res);
        free(d_batch);
        free_vec_batch(d, B);
    }
    else if (strcmp(operation, "matMul") == 0) {
        ancora_mat M;
        ancora_zonotope *res = alloc_zonotope_batch(B, n, m);
        ancora_zonotope **res_batch = malloc((size_t)B * sizeof(ancora_zonotope *));
        if (!res || !res_batch) { rc = fail("alloc res batch"); goto cleanup; }
        for (slong b = 0; b < B; b++) res_batch[b] = &res[b];
        if (make_random_matrix(&M, n) != ANCORA_OK) { rc = fail("make matrix"); goto cleanup; }
        for (slong r = 0; r < repetition; r++) {
            if (ancora_zonotope_batched_matMul(res_batch, &M, Z_batch, B) != ANCORA_OK) {
                rc = fail("zonotope batched matMul");
                goto cleanup;
            }
        }
        ancora_mat_free(&M);
        free(res_batch);
        free_zonotope_batch(res, B);
    }
    else if (strcmp(operation, "minkSum") == 0) {
        ancora_zonotope *Z2 = alloc_zonotope_batch(B, n, m);
        ancora_zonotope *res = alloc_zonotope_batch(B, n, 2 * m);
        const ancora_zonotope **Z2_batch = malloc((size_t)B * sizeof(const ancora_zonotope *));
        ancora_zonotope **res_batch = malloc((size_t)B * sizeof(ancora_zonotope *));
        if (!Z2 || !res || !Z2_batch || !res_batch) { rc = fail("alloc minkSum batches"); goto cleanup; }
        for (slong b = 0; b < B; b++) { Z2_batch[b] = &Z2[b]; res_batch[b] = &res[b]; }
        for (slong r = 0; r < repetition; r++) {
            if (ancora_zonotope_batched_minkowskiSum(res_batch, Z_batch, Z2_batch, B) != ANCORA_OK) {
                rc = fail("zonotope batched minkSum");
                goto cleanup;
            }
        }
        free(res_batch);
        free(Z2_batch);
        free_zonotope_batch(res, B);
        free_zonotope_batch(Z2, B);
    }
    else if (strcmp(operation, "contains") == 0) {
        ancora_mat *P = alloc_mat_batch(B, n, points);
        const ancora_mat **P_batch = malloc((size_t)B * sizeof(const ancora_mat *));
        ancora_truth contained;
        if (!P || !P_batch) { rc = fail("alloc P batch"); goto cleanup; }
        for (slong b = 0; b < B; b++) {
            P_batch[b] = &P[b];
            if (ancora_zonotope_randomPoints_standard(&P[b], &batch[b], points) != ANCORA_OK) {
                rc = fail("draw points");
                goto cleanup;
            }
        }
        for (slong r = 0; r < repetition; r++) {
            if (ancora_zonotope_batched_containsPoints(Z_batch, P_batch, B, &contained) != ANCORA_OK) {
                rc = fail("zonotope batched contains");
                goto cleanup;
            }
            if (!ancora_yes(contained)) { rc = fail("zonotope batched contains returned false"); goto cleanup; }
        }
        free(P_batch);
        free_mat_batch(P, B);
    }
    else {
        rc = fail("unknown zonotope operation");
    }

cleanup:
    free(Z_batch);
    free_zonotope_batch(batch, B);
    return rc;
}

/* ------------------------------------------------------------------ */
/* main                                                                */
/* ------------------------------------------------------------------ */

int main(int argc, char **argv)
{
    if (argc < 8) {
        fprintf(stderr,
                "usage: %s <set> <operation> <dim> <generators> <batch_size> "
                "<repetition> <points> [type]\n",
                argv[0]);
        return 2;
    }
    const char *set = argv[1];
    const char *operation = argv[2];
    slong n = atol(argv[3]);
    slong generators = atol(argv[4]);
    slong B = atol(argv[5]);
    slong repetition = atol(argv[6]);
    slong points = atol(argv[7]);
    /* argv[8] = type ("standard" / "upper"); not needed to dispatch. */

    /* Deterministic seed so runs are reproducible. */
    ancora_random_setSeed(42);

    /* The `test` benchmark: initialize one zonotope of dimension 1. */
    if (strcmp(operation, "startup") == 0) {
        ancora_zonotope Z;
        if (init_zonotope_dim(&Z, 1, 1) != ANCORA_OK) return 1;
        ancora_zonotope_free(&Z);
        return 0;
    }

    if (strcmp(set, "interval") == 0) {
        if (B > 1)
            return run_interval_batched(operation, n, points, B, repetition);
        else
            return run_interval_unbatched(operation, n, points, repetition);
    }
    else if (strcmp(set, "zonotope") == 0) {
        if (B > 1)
            return run_zonotope_batched(operation, n, generators, points, B, repetition);
        else
            return run_zonotope_unbatched(operation, n, generators, points, repetition);
    }

    fprintf(stderr, "ancora_benchmark: unknown set '%s'\n", set);
    return 2;
}
