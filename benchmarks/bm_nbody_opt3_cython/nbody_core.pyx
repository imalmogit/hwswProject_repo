# cython: language_level=3, boundscheck=False, wraparound=False, cdivision=True
#
# Typed core for the nbody benchmark.
#
# The whole advance() loop runs on C doubles held in fixed C arrays, so no
# PyFloatObject is allocated, no operator dispatch happens, and no Python
# integer is converted to an index inside the loop. State is marshalled in
# from the Python body list once, and written back once at the end -- the
# software analogue of handing a block of work to an accelerator.

from libc.math cimport sqrt

DEF MAX_BODIES = 16


def advance_c(double dt, int n, list bodies):
    cdef int nb = len(bodies)
    if nb > MAX_BODIES:
        raise ValueError("advance_c supports at most %d bodies" % MAX_BODIES)

    cdef double pos[MAX_BODIES][3]
    cdef double vel[MAX_BODIES][3]
    cdef double mass[MAX_BODIES]
    cdef int i, j, it
    cdef double dx, dy, dz, d2, mag, b1m, b2m
    cdef list r, v

    # ---- marshal in ----
    for i in range(nb):
        r = <list>bodies[i][0]
        v = <list>bodies[i][1]
        pos[i][0] = r[0]; pos[i][1] = r[1]; pos[i][2] = r[2]
        vel[i][0] = v[0]; vel[i][1] = v[1]; vel[i][2] = v[2]
        mass[i] = bodies[i][2]

    # ---- compute ----
    # Pair order (0,1),(0,2),...,(n-2,n-1) matches combinations() in the
    # original, so floating-point accumulation order is preserved.
    for it in range(n):
        for i in range(nb - 1):
            for j in range(i + 1, nb):
                dx = pos[i][0] - pos[j][0]
                dy = pos[i][1] - pos[j][1]
                dz = pos[i][2] - pos[j][2]
                d2 = dx * dx + dy * dy + dz * dz
                mag = dt / (d2 * sqrt(d2))
                b1m = mass[i] * mag
                b2m = mass[j] * mag
                vel[i][0] -= dx * b2m
                vel[i][1] -= dy * b2m
                vel[i][2] -= dz * b2m
                vel[j][0] += dx * b1m
                vel[j][1] += dy * b1m
                vel[j][2] += dz * b1m
        for i in range(nb):
            pos[i][0] += dt * vel[i][0]
            pos[i][1] += dt * vel[i][1]
            pos[i][2] += dt * vel[i][2]

    # ---- marshal out ----
    for i in range(nb):
        r = <list>bodies[i][0]
        v = <list>bodies[i][1]
        r[0] = pos[i][0]; r[1] = pos[i][1]; r[2] = pos[i][2]
        v[0] = vel[i][0]; v[1] = vel[i][1]; v[2] = vel[i][2]
