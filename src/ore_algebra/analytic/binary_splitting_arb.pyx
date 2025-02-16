# cython: language=c++
# cython: language_level=3
# distutils: extra_compile_args = -std=c++11
r"""
Lower-level reimplementation of key subroutines of binary_splitting
"""

# Copyright 2018 Marc Mezzarobba
# Copyright 2018 Centre national de la recherche scientifique
# Copyright 2018 Université Pierre et Marie Curie
#
# Distributed under the terms of the GNU General Public License (GPL) either
# version 2, or (at your option) any later version
#
# http://www.gnu.org/licenses/

from sage.libs.arb.types cimport *
from sage.libs.arb.acb cimport *
from sage.libs.arb.acb_poly cimport *
from sage.libs.arb.acb_mat cimport *
from sage.libs.flint.fmpz cimport *
from sage.libs.flint.fmpq_poly cimport *
from sage.libs.flint.fmpz_poly cimport *

from sage.matrix.matrix_complex_ball_dense cimport Matrix_complex_ball_dense
from sage.rings.complex_arb cimport ComplexBall
from sage.rings.polynomial.polynomial_complex_arb cimport Polynomial_complex_arb
from sage.rings.polynomial.polynomial_element cimport Polynomial

import cython

from . import binary_splitting

cdef inline acb_mat_struct* acb_mat_poly_coeff_ptr(Polynomial p, long i):
    cdef list coeffs = p.list(copy=False)
    if i >= len(coeffs):
        return NULL
    else:
        return (<Matrix_complex_ball_dense> (coeffs[i])).value

# may become a cdef class (and no longer inherit from the Python version) in
# the future
class StepMatrix_arb(binary_splitting.StepMatrix_arb):

    def _coeff_series_num_den(self, rec, py_n, ord_log):

        cdef bint success
        cdef ComplexBall den
        cdef Polynomial_complex_arb val_pert
        cdef acb_struct* c
        cdef acb_t n, lc0, lc0pow
        cdef acb_poly_struct* lc
        cdef fmpz_poly_t lcz
        cdef fmpq_poly_t lcq
        cdef ssize_t prec_inv
        cdef ssize_t reclen = len(rec.bwrec.coeff)
        cdef list bwrec_n = [None]*reclen

        cdef ssize_t mult = rec.mult(py_n)
        cdef ssize_t prec = rec.bwrec.Scalars.precision()

        acb_init(n)
        acb_set_si(n, py_n)
        for i in range(reclen):
            val_pert = Polynomial_complex_arb.__new__(Polynomial_complex_arb)
            val_pert._parent = rec.bwrec.base_ring
            # Only needed to order ord_log + mult, but compose_series requires
            # the inner polynomial to have valuation > 0.
            # TODO: Maybe use evaluate or evaluate2 instead when applicable.
            acb_poly_taylor_shift(
                    val_pert._poly,
                    (<Polynomial_complex_arb> (rec.bwrec.coeff[i]))._poly,
                    n, prec)
            acb_poly_truncate(
                    val_pert._poly,
                    ord_log + mult)
            bwrec_n[i] = val_pert
        acb_clear(n)

        den = ComplexBall.__new__(ComplexBall)
        den._parent = rec.bwrec.Scalars

        lc = (<Polynomial_complex_arb> (bwrec_n[0]))._poly
        for i in range(mult):
            assert acb_contains_zero(acb_poly_get_coeff_ptr(lc, i)), "!= 0"
        acb_poly_shift_right(lc, lc, mult)

        # Compute the inverse exactly

        cdef ssize_t ord_inv = ord_log# + mult
        # cdef ssize_t ord_inv = ord_log
        if acb_poly_is_real(lc):
            # Work over ℚ to reduce the bit size of the result
            fmpq_poly_init(lcq)
            fmpz_poly_init(lcz)
            success = acb_poly_get_unique_fmpz_poly(lcz, lc)
            assert success, "acb -> fmpz " + str(bwrec_n[0])
            fmpq_poly_set_fmpz_poly(lcq, lcz)
            fmpz_poly_clear(lcz)
            fmpq_poly_inv_series(lcq, lcq, ord_inv)
            acb_set_fmpz(den.value, fmpq_poly_denref(lcq))
            fmpz_one(fmpq_poly_denref(lcq))
            acb_poly_set_fmpq_poly(lc, lcq, prec)
            fmpq_poly_clear(lcq)
        else:
            # Reduce to a unit constant coefficient. Temporarily increase the
            # (bit) working precision by the expected size of the denominator
            # to keep at least the computation of the inverse exact, but the
            # result may not fit on prec bits, and the coefficients may be huge
            # :-(
            acb_init(lc0)
            acb_poly_fit_length(lc, ord_inv)
            acb_poly_get_coeff_acb(lc0, lc, 0)
            prec_inv = prec + ord_inv*(acb_bits(lc0) + 1)
            acb_init(lc0pow)
            # lc ← lc(lc[0]*x)/lc[0]
            acb_one(acb_poly_get_coeff_ptr(lc, 0))
            acb_one(lc0pow)
            for i in range(2, ord_log): # lc[i] ← lc[0]^(i-1)·lc[i]
                acb_mul(lc0pow, lc0pow, lc0, prec_inv)
                c = acb_poly_get_coeff_ptr(lc, i)
                acb_mul(c, c, lc0pow, prec_inv)
            # typically but perhaps not always exact
            acb_poly_inv_series(lc, lc, ord_inv, prec_inv)
            acb_one(lc0pow)
            acb_poly_fit_length(lc, ord_inv)
            for i in range(ord_inv-2, -1, -1):
                acb_mul(lc0pow, lc0pow, lc0, prec_inv)
                c = acb_poly_get_coeff_ptr(lc, i)
                acb_mul(c, c, lc0pow, prec_inv)
            acb_mul(lc0pow, lc0pow, lc0, prec_inv) # lc[0]^ord_inv
            acb_set(den.value, lc0pow)
            acb_clear(lc0pow)
            acb_clear(lc0)

        for i in range(rec.ordrec):
            acb_poly_mullow(
                    (<Polynomial_complex_arb> (bwrec_n[1+i]))._poly,
                    (<Polynomial_complex_arb> (bwrec_n[1+i]))._poly,
                    lc, ord_log, prec)

        # TODO: implement the gcd of Gaussian integers represented as acb
        # balls, use it to remove a common factor between bwrec_n and den

        bwrec_n[0] = 0 # clears lc

        return bwrec_n, den

    @staticmethod
    def _seq_init(rec, ord_log):
        # Ensure that we start with new objects (not cached zeros and ones), as
        # _seq_next is going to modify them

        cdef ComplexBall zero = <ComplexBall> rec.AlgInts_sums.zero()
        row = [[[[zero._new() for _ in range(rec.derivatives)]
                 for _ in range(ord_log)]
                for _ in range(rec.ordrec)]
               for _ in range(rec.npoints)]

        cdef Polynomial_complex_arb zpol = rec.Pols_rec.zero()
        seqs = [[zpol._new() for _ in range(rec.ordrec)]
                for _ in range(rec.ordrec)]
        for k in range(1, rec.ordrec + 1):
            acb_poly_one((<Polynomial_complex_arb> (seqs[-k][-k]))._poly)

        return zero, row, seqs

    @cython.boundscheck(False)
    @cython.wraparound(False)
    def _seq_next_psum(self, psum, py_num, py_pow_num, py_den, py_ord_log):

        # Cython version to avoid the (currently very large) overhead of
        # accessing the coefficients of arb polynomials from Python

        cdef acb_ptr a, b
        cdef ComplexBall c
        cdef ssize_t p, q

        cdef list num = <list> py_num
        cdef Polynomial_complex_arb pow_num = <Polynomial_complex_arb> py_pow_num
        cdef ComplexBall den = <ComplexBall> py_den
        cdef unsigned int ord_log = <unsigned int> py_ord_log

        cdef ssize_t len_num = len(num)
        cdef Polynomial_complex_arb mynum = <Polynomial_complex_arb> (num[len_num-1])

        cdef unsigned int ord_diff = <unsigned int> self.ord_diff
        cdef long prec = den._parent._prec

        for q in range(ord_log):
            for p in range(ord_diff):
                a = acb_poly_get_coeff_ptr(pow_num._poly, p)
                b = acb_poly_get_coeff_ptr(mynum._poly, q)
                c = <ComplexBall> ((<list> (<list> psum)[q])[p])
                if a != NULL and b != NULL:
                    acb_addmul(c.value, a, b, prec)
                acb_mul(c.value, c.value, den.value, prec)

    @cython.boundscheck(False)
    @cython.wraparound(False)
    def _seq_next_num(self, py_num, py_bwrec_n, py_rec_den_n, py_ord_log):

        # Cython version to avoid the (currently very large) overhead of
        # accessing the coefficients of arb polynomials from Python

        cdef ssize_t k
        cdef Polynomial_complex_arb coef
        cdef acb_poly_t tmppol, u_n

        cdef list num = <list> py_num
        cdef list bwrec_n = <list> py_bwrec_n
        cdef ComplexBall rec_den_n = <ComplexBall> py_rec_den_n
        cdef unsigned int ord_log = <unsigned int> py_ord_log

        cdef ssize_t len_num = len(num)
        cdef Polynomial_complex_arb mynum = <Polynomial_complex_arb> (num[len_num-1])

        cdef unsigned int ord_diff = <unsigned int> self.ord_diff
        cdef long prec = mynum._parent._base._prec

        acb_poly_init(u_n)

        acb_poly_init(tmppol)
        for k in range(1, len(bwrec_n)):
            coef = <Polynomial_complex_arb> (bwrec_n[k])
            mynum = <Polynomial_complex_arb> (num[len_num-k])
            acb_poly_mullow(tmppol, coef._poly, mynum._poly, ord_log, prec)
            acb_poly_sub(u_n, u_n, tmppol, prec)
        acb_poly_clear(tmppol)

        for k in range(len_num - 1):
            acb_poly_scalar_mul(
                    (<Polynomial_complex_arb> num[k])._poly,
                    (<Polynomial_complex_arb> num[k+1])._poly,
                    rec_den_n.value, prec)

        acb_poly_swap((<Polynomial_complex_arb> num[len_num-1])._poly, u_n)
        acb_poly_clear(u_n)

    @cython.boundscheck(False)
    @cython.wraparound(False)
    def compute_sums_row(low, high, py_i):

        cdef ssize_t j, q, p, k, u, v
        cdef acb_ptr a, b, c
        cdef ComplexBall entry
        cdef acb_mat_struct *mat
        cdef list l

        cdef ssize_t i = <ssize_t> (py_i)

        Scalars = high.zero_sum.parent()

        cdef unsigned int ordrec = high.rec_mat.base_ring().nrows()
        cdef unsigned long prec = Scalars.precision()

        cdef acb_poly_struct *low_pow_num # why isn't this working with _ptr?
        low_pow_num = (<Polynomial_complex_arb> ((<list> low.pow_num)[i]))._poly
        cdef Polynomial low_rec_mat = <Polynomial> (low.rec_mat)

        cdef acb_t high_den
        acb_init(high_den)
        acb_mul(high_den, (<ComplexBall> high.rec_den).value,
                          (<ComplexBall> ((<list> high.pow_den)[i])).value,
                prec)

        # sums_row[i] = high.sums_row[i]*low.rec_mat*low.pow_num[i]
        #                   δ, Sk, row     Sk, mat      δ
        #
        #            + high.rec_den*high.pow_den[i]*low.sums_row[i]
        #                 cst (nf)        cst        δ, Sk, row

        cdef acb_t t
        acb_init(t)

        res1 = [None]*len((<list> high.sums_row)[i])
        for j in xrange(ordrec):
            res2 = [None]*high.ord_log
            for q in xrange(high.ord_log):
                res3 = [None]*low.ord_diff
                for p in xrange(low.ord_diff):

                    entry = ComplexBall.__new__(ComplexBall)
                    entry._parent = Scalars
                    acb_zero(entry.value)

                    # explicit casts to acb_ptr and friends are there as a
                    # workaround for cython bug #1984

                    # one coefficient of one entry the first term
                    # high.sums_row*low.rec_mat*low.pow_num
                    # TODO: try using acb_dot? how?
                    for k in xrange(ordrec):
                        for u in xrange(p + 1):
                            for v in xrange(q + 1):
                                l = <list> (high.sums_row)
                                l = <list> (l[i])
                                l = <list> (l[k])
                                l = <list> (l[v])
                                a = <acb_ptr> (<ComplexBall> l[u]).value
                                b = acb_poly_get_coeff_ptr(low_pow_num, p-u)
                                if b == NULL:
                                    continue
                                mat = acb_mat_poly_coeff_ptr(low_rec_mat, q-v)
                                if mat == NULL:
                                    continue
                                c = acb_mat_entry(mat, k, j)
                                acb_mul(t, b, c, prec)
                                acb_addmul(entry.value, t, a, prec)

                    # same for the second term
                    # high.rec_den*pow_den.rec_den*low.sums_row
                    if q < low.ord_log: # usually true, but low might be
                                        # an optimized SolutionColumn
                        l = <list> low.sums_row
                        l = <list> (l[i])
                        l = <list> (l[j])
                        l = <list> (l[q])
                        a = <acb_ptr> ((<ComplexBall> l[p]).value)
                        acb_addmul(entry.value, high_den, a, prec)

                    res3[p] = entry
                res2[q] = res3
            res1[j] = res2

        acb_clear(high_den)
        acb_clear(t)

        return res1
