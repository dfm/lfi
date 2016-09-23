# distutils: language = c++
from __future__ import division

cimport cython
from libc.math cimport exp, log
from libcpp.vector cimport vector
from libcpp.string cimport string

import time
import numpy as np
cimport numpy as np

DTYPE = np.float64
ctypedef np.float64_t DTYPE_t

DTYPE_u = np.uint32
ctypedef np.uint32_t DTYPE_u_t


cdef extern from "boost/random.hpp" namespace "boost::random":

    cdef cppclass mt19937:
        mt19937()
        mt19937(unsigned seed)


cdef extern from "exoabc/exoabc.h" namespace "exoabc":

    ctypedef mt19937 random_state_t

    # Distributions
    cdef cppclass BaseParameter:
        pass
    cdef cppclass Distribution:
        pass
    cdef cppclass Uniform(Distribution):
        Uniform(double, double)
    cdef cppclass Delta:
        Delta(double)
    cdef cppclass Parameter(BaseParameter):
        Parameter(double)
        Parameter(Distribution*)
        Parameter(Distribution*, random_state_t)
        Parameter(Distribution*, double)
    cdef cppclass PowerLaw(Distribution):
        PowerLaw(double, double, BaseParameter*)
    cdef cppclass Normal(Distribution):
        Normal(BaseParameter*, BaseParameter*)
    cdef cppclass Beta(Distribution):
        Beta(BaseParameter*, BaseParameter*)
    cdef cppclass Rayleigh(Distribution):
        Rayleigh(BaseParameter*)
    cdef cppclass Multinomial(Distribution):
        Multinomial(BaseParameter*)
        void add_bin(Parameter*)

    # Observation model
    cdef cppclass CompletenessModel:
        pass
    cdef cppclass Q1_Q16_CompletenessModel(CompletenessModel):
        pass
    cdef cppclass Q1_Q17_CompletenessModel(CompletenessModel):
        Q1_Q17_CompletenessModel (
            double qmax_m, double qmax_b,
            double mes0_m, double mes0_b,
            double lnw_m, double lnw_b
        )
    cdef cppclass Star:
        Star (
            const CompletenessModel* completeness_model,
            double mass, double radius, double dataspan, double dutycycle,
            unsigned n_cdpp, const double* cdpp_x, const double* cdpp_y,
            unsigned n_thresh, const double* thresh_x, const double* thresh_y
        )

    # Simulation
    cdef cppclass CatalogRow:
        unsigned starid
        double period
        double radius
        double duration
        double depth

    cdef cppclass Simulation:
        Simulation (
            Distribution* period_distribution,
            Distribution* radius_distribution,
            Distribution* eccen_distribution,
            Distribution* width_distribution,
            Distribution* multi_distribution
        )
        void add_star (Star* star)
        vector[CatalogRow] sample_population (random_state_t) nogil

    #     void clean_up ()
    #     Simulation* copy()
    #     string get_state ()
    #     string get_state (unsigned seed)
    #     void set_state (string state)

    #     void add_star (Star* star)
    #     vector[CatalogRow] sample_population () nogil

# cdef extern from "completeness.h" namespace "exopop":

    # cdef cppclass CompletenessModel:
    #     CompletenessModel ()

    # cdef cppclass Q1_Q17_CompletenessModel(CompletenessModel):
    #     Q1_Q17_CompletenessModel (double, double, double, double, double, double)

    # cdef cppclass Star:
    #     Star ()
    #     Star (
    #         CompletenessModel* completeness_model,
    #         double mass, double radius,
    #         double dataspan, double dutycycle,
    #         unsigned n_cdpp, const double* cdpp_x, const double* cdpp_y,
    #         unsigned n_thresh, const double* thresh_x, const double* thresh_y
    #     )


cdef class Simulator:
    """
    This class provides functionality for simulating a population of exoplanets
    around a set of Kepler targets. This uses the Burke et al. (2015)
    semi-analytic completeness model.

    """

    # cdef unsigned nplanets
    # cdef unsigned cached
    # cdef object period_range
    # cdef object radius_range
    # cdef Simulation* cached_simulator

    cdef random_state_t     state
    cdef Simulation*        simulation
    cdef CompletenessModel* completeness_model

    def __cinit__(self, stars,
                  double min_period, double max_period, double period_slope,
                  double min_radius, double max_radius, double radius_slope,
                  double log_sigma, log_multi_params,
                  double min_period_slope=-4.0, double max_period_slope=3.0,
                  double min_radius_slope=-4.0, double max_radius_slope=3.0,
                  double min_log_sigma=-10.0, double max_log_sigma=1.0,
                  double min_log_multi=-5.0, double max_log_multi=2.0,
                  eccen_params=(0.867, 3.03),
                  seed=None, release=None, completeness_params=None):
        # Set up the random state
        cdef unsigned iseed
        if seed is None:
            iseed = int(time.time())
        else:
            iseed = int(seed)
        self.state = random_state_t(iseed)

        # Figure out which completeness model to use
        if release is None:
            release = "q1_q16"
        if release == "q1_q16":
            self.completeness_model = new Q1_Q16_CompletenessModel()
        elif release == "q1_q17":
            completeness_params = np.atleast_1d(completeness_params)
            if not completeness_params.shape == (6, ):
                raise ValueError("completeness parameters dimension mismatch")
            self.completeness_model = new Q1_Q17_CompletenessModel(
                completeness_params[0], completeness_params[1],
                completeness_params[2], completeness_params[3],
                completeness_params[4], completeness_params[5],
            )
        else:
            raise ValueError("unrecognized release: '{0}'".format(release))

        # Set up the simulation distributions
        cdef PowerLaw* period = new PowerLaw(
            min_period, max_period,
            new Parameter(new Uniform(min_period_slope, max_period_slope),
                          period_slope)
        )
        cdef PowerLaw* radius = new PowerLaw(
            min_radius, max_radius,
            new Parameter(new Uniform(min_radius_slope, max_radius_slope),
                          radius_slope)
        )
        cdef Beta* eccen = new Beta(new Parameter(log(eccen_params[0])),
                                    new Parameter(log(eccen_params[1])))
        cdef Rayleigh* width = new Rayleigh(
            new Parameter(new Uniform(min_log_sigma, max_log_sigma), log_sigma)
        )
        cdef np.ndarray[DTYPE_t, ndim=1] lmp = np.atleast_1d(log_multi_params)
        cdef Multinomial* multi = new Multinomial(new Parameter(0.0))
        cdef Parameter* par
        cdef double v
        for v in log_multi_params:
            par = new Parameter(new Uniform(min_log_multi, max_log_multi), v)
            multi.add_bin(par)

        # Build the simulator
        self.simulation = new Simulation(period, radius, eccen, width, multi)

        # Add in the stars from the catalog
        cdef Star* starobj
        cdef np.ndarray[DTYPE_t, ndim=1] cdpp_x
        cdef np.ndarray[DTYPE_t, ndim=1] cdpp_y
        cdef np.ndarray[DTYPE_t, ndim=1] thr_x
        cdef np.ndarray[DTYPE_t, ndim=1] thr_y
        for _, star in stars.iterrows():
            # Pull out the CDPP values.
            cdpp_cols = [k for k in star.keys() if k.startswith("rrmscdpp")]
            cdpp_x = np.array([k[-4:].replace("p", ".") for k in cdpp_cols],
                              dtype=float)
            inds = np.argsort(cdpp_x)
            cdpp_x = np.ascontiguousarray(cdpp_x[inds], dtype=np.float64)
            cdpp_y = np.ascontiguousarray(star[cdpp_cols][inds],
                                          dtype=np.float64)

            # And the MES thresholds.
            thr_cols = [k for k in star.keys() if k.startswith("mesthres")]
            thr_x = np.array([k[-4:].replace("p", ".") for k in thr_cols],
                             dtype=float)
            inds = np.argsort(thr_x)
            thr_x = np.ascontiguousarray(thr_x[inds], dtype=np.float64)
            thr_y = np.ascontiguousarray(star[thr_cols][inds],
                                         dtype=np.float64)

            # Put the star together
            starobj = new Star(
                self.completeness_model,
                star.mass, star.radius, star.dataspan, star.dutycycle,
                cdpp_x.shape[0], <double*>cdpp_x.data, <double*>cdpp_y.data,
                thr_x.shape[0], <double*>thr_x.data, <double*>thr_y.data,
            )
            self.simulation.add_star(starobj)

    def __dealloc__(self):
        del self.simulation
        del self.completeness_model

    def sample_population(self):
        cdef vector[CatalogRow] catalog
        with nogil:
            catalog = self.simulation.sample_population(self.state)

        # Convert the simulation to a numpy array
        result = np.empty(catalog.size(), dtype=[
            ("kicid", int), ("koi_period", float), ("koi_prad", float),
            ("koi_duration", float), ("koi_depth", float)
        ])
        cdef int i
        for i in range(catalog.size()):
            result["kicid"][i] = catalog[i].starid
            result["koi_period"][i] = catalog[i].period
            result["koi_prad"][i] = catalog[i].radius
            result["koi_duration"][i] = catalog[i].duration
            result["koi_depth"][i] = catalog[i].depth
        return result

    # def observe(self, np.ndarray[DTYPE_t, ndim=1] params, state=None):
    #     """
    #     Observe the current simulation for a given set of hyperparameters.
    #     The parameters are as follows:

    #     .. code-block:: python
    #         [radius_power1, radius_power2, radius_break,
    #          period_power1, period_power2, period_break,
    #          std_of_incl_distribution, ln_multiplicity...(nmax parameters)]

    #     :param state: (optional)
    #         The random state can be provided to ensure a specific catalog.

    #     """
    #     if params.shape[0] != 7 + self.nplanets - 1:
    #         raise ValueError("dimension mismatch")

    #     cdef np.ndarray[DTYPE_u_t, ndim=1] counts = np.empty(self.nplanets,
    #                                                          dtype=DTYPE_u)

    #     if state is not None:
    #         self.simulator.set_state(state)
    #     else:
    #         state = self.simulator.get_state()
    #     self.simulator.resample()

    #     cdef int flag
    #     cdef vector[CatalogRow] catalog
    #     cdef Simulation* sim = self.simulator
    #     cdef double* p = <double*>params.data
    #     cdef unsigned* c = <unsigned*>counts.data
    #     with nogil:
    #         catalog = sim.observe(p, c, &flag)

    #     if flag:
    #         raise RuntimeError("simulator failed with status {0}".format(flag))

    #     # Copy the catalog.
    #     cdef int i
    #     cdef np.ndarray[DTYPE_u_t, ndim=1] starids = np.empty(catalog.size(),
    #                                                           dtype=DTYPE_u)
    #     cdef np.ndarray[DTYPE_t, ndim=2] cat_out = np.empty((catalog.size(), 2),
    #                                                         dtype=DTYPE)
    #     for i in range(cat_out.shape[0]):
    #         starids[i] = catalog[i].starid
    #         cat_out[i, 0] = catalog[i].period
    #         cat_out[i, 1] = catalog[i].radius

    #     return counts, starids, cat_out, state

    # def resample(self):
    #     """
    #     Re-sample all the per-planet and per-star parameters from their priors.

    #     """
    #     self.simulator.resample()

    # def revert(self):
    #     if self.cached:
    #         del self.simulator
    #         self.simulator = self.cached_simulator
    #         self.cached = 0

    # def perturb(self):
    #     """
    #     Randomly re-sample one set of per-planet or per-star parameters (i.e.
    #     all the periods or radii or whatever) from the prior.

    #     """
    #     # First, cache the current simulation state for reverting.
    #     if self.cached:
    #         del self.cached_simulator
    #     self.cached_simulator = self.simulator.copy()
    #     self.cached = 1

    #     # Then select a parameter to update.
    #     cdef int ind = np.random.randint(11)
    #     if ind == 0:
    #         self.simulator.resample_multis()
    #     elif ind == 1:
    #         self.simulator.resample_q1()
    #     elif ind == 2:
    #         self.simulator.resample_q2()
    #     elif ind == 3:
    #         self.simulator.resample_incls()
    #     elif ind == 4:
    #         self.simulator.resample_radii()
    #     elif ind == 5:
    #         self.simulator.resample_periods()
    #     elif ind == 6:
    #         self.simulator.resample_eccens()
    #     elif ind == 7:
    #         self.simulator.resample_omegas()
    #     elif ind == 8:
    #         self.simulator.resample_mutual_incls()
    #     elif ind == 9:
    #         self.simulator.resample_delta_incls()
    #     elif ind == 10:
    #         self.simulator.resample_obs_randoms()

    # def get_state(self, seed=None):
    #     if seed is None:
    #         return self.simulator.get_state()
    #     return self.simulator.get_state(int(seed))

    # def set_state(self, bytes state):
    #     self.simulator.set_state(state)
