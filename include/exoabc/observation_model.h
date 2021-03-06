#ifndef _EXOABC_COMPLETENESS_H_
#define _EXOABC_COMPLETENESS_H_

#include <cmath>
#include <cfloat>
#include <vector>
#include <boost/math/distributions/gamma.hpp>

#include "exoabc/transit/quad.h"
#include "exoabc/distributions.h"

namespace exoabc {

// G / (4 * pi)
#define GRAV_OVER_4_PI 74.6094376947028

// Earth radius in Solar radii
#define RADIUS_EARTH   0.009171

class CompletenessModel {
public:
  CompletenessModel () {};
  virtual ~CompletenessModel () {};

  virtual double get_mes (double period, double depth, double sigma, double total_time) const {
    double snr = depth / sigma,
           ntrn = total_time / period;
    return snr * sqrt(ntrn);
  };

  virtual double get_pdet (double period, double mes, double mest) const {
    if (mes >= mest) return 1.0;
    return 0.0;
  };

  virtual double get_pwin (double period, double dataspan, double dutycycle) const {
    double M = dataspan / period;
    if (M <= 2.0) return 0.0;
    double f = dutycycle,
            omf = 1.0 - f,
            pw = 1 - pow(omf, M) - M*f*pow(omf, M-1) - 0.5*M*(M-1)*f*f*pow(omf, M-2);
    if (pw < 0.0) return 0.0;
    return pw;
  };
};

//
// The Q1-Q16 completeness model
//
class Q1_Q16_CompletenessModel : public CompletenessModel {
public:
  Q1_Q16_CompletenessModel () : gamma_(4.65, 0.98) {};
  double get_pdet (double period, double mes, double mest) const {
    double x = mes - 4.1 - (mest - 7.1);
    if (x <= 0.0) return 0.0;
    return boost::math::cdf(gamma_, x);
  };
private:
  boost::math::gamma_distribution<> gamma_;
};

//
// The Q1-Q17 completeness model that we'll use for now is a logistic function:
//
//  Q(period, MES) = Q_max(period) / (1 + exp(-(MES-MES_0(period))/exp(lnw(period))))
//
// where Q_max is bounded to (0, 1) and all parameters are linear functions of
// period. For a given stellar sample, we'll find the maximum likelihood linear
// coefficients for each component.
//
class Q1_Q17_CompletenessModel : public CompletenessModel {
public:
  Q1_Q17_CompletenessModel (
    std::vector<double> period_bin_edges,
    std::vector<double> qmax, std::vector<double> mes0, std::vector<double> lnw
  )
  : period_bin_edges_(period_bin_edges), qmax_(qmax), mes0_(mes0), invw_(lnw)
  {
    for (size_t i = 0; i < invw_.size(); ++i) invw_[i] = exp(-invw_[i]);
  };

  double get_pdet (double period, double mes, double mest) const {
    if (period < period_bin_edges_[0]) return 0.0;
    if (period > period_bin_edges_[period_bin_edges_.size()-1]) return 0.0;

    size_t i;
    for (i = 1; i < period_bin_edges_.size(); ++i) if (period < period_bin_edges_[i]) break;
    if (i >= period_bin_edges_.size()) return 0.0;

    double qmax = qmax_[i-1], mes0 = mes0_[i-1], invw = invw_[i-1],
           y = qmax / (1.0 + exp(-(mes - mes0) * invw));
    if (y <= 0.0) return 0.0;
    if (y >= 1.0) return 1.0;
    return y;
  };

private:
  std::vector<double> period_bin_edges_, qmax_, mes0_, invw_;
};


class BaseStar {
public:
  virtual ~BaseStar () {};
  virtual double get_completeness (double mass, double radius, double q1, double q2,
                                   double period, double rp,
                                   double incl, double e, double omega,
                                   double* duration, double* depth) const = 0;
  virtual double sample_mass (random_state_t& state) const = 0;
  virtual double sample_radius (random_state_t& state) const = 0;
};


class Star : public BaseStar {
public:
  Star (
    const CompletenessModel* completeness_model,
    double ln_mass, double sigma_ln_mass, double ln_radius, double sigma_ln_radius,
    double dataspan, double dutycycle,
    unsigned n_cdpp, const double* cdpp_x, const double* cdpp_y,
    unsigned n_thresh, const double* thresh_x, const double* thresh_y
  )
  : ln_mass_(ln_mass)                              // ln(M_Sun)
  , sigma_ln_mass_(sigma_ln_mass)                  // uncert ln(M_Sun)
  , ln_radius_(ln_radius)                          // ln(R_Sun)
  , sigma_ln_radius_(sigma_ln_radius)              // uncert ln(R_Sun)
  , dataspan_(dataspan)                            // days
  , dutycycle_(dutycycle)                          // arbitrary
  , timefactor_(dataspan*dutycycle)
  , cdpp_x_(n_cdpp)                                // durations in hours
  , cdpp_y_(n_cdpp)                                // ppm
  , thresh_x_(n_thresh)                            // durations in hours
  , thresh_y_(n_thresh)                            // MES
  , completeness_model_(completeness_model)
  {
    for (unsigned i = 0; i < n_cdpp; ++i) {
      cdpp_x_[i] = cdpp_x[i];
      cdpp_y_[i] = cdpp_y[i];
    }
    for (unsigned i = 0; i < n_thresh; ++i) {
      thresh_x_[i] = thresh_x[i];
      thresh_y_[i] = thresh_y[i];
    }
  };

  double get_a (double period, double mass) const {
    return pow(GRAV_OVER_4_PI * period * period * mass, 1./3);
  };
  double get_impact (double aor, double incl, double e, double omega) const {
    return std::abs(aor * cos(incl) * (1.0 - e * e) / (1.0 + e * sin(omega)));
  };
  double get_duration (double aor, double period, double ror, double b,
                       double incl, double e, double omega) const {
    double duration, opr, arg, b2 = b*b;
    opr = 1.0 + ror;
    opr *= opr;
    if (b2 >= opr) return 0.0;
    arg = sqrt(opr - b2) / aor / sin(incl);
    duration = period / M_PI * asin(arg);
    if (e > DBL_EPSILON)
      duration *= sqrt(1.0 - e*e) / (1.0 + e * sin(omega));
    return duration;
  }

  double get_depth (double q1, double q2, double ror, double b) const {
    double params[2] = {q1, q2};
    transit::QuadraticLimbDarkening ld;
    return 1.0e6 * (1.0 - ld(params, ror, b));
  };

  double get_completeness (double mass, double radius, double q1, double q2,
                           double period, double rp,
                           double incl, double e, double omega,
                           double* duration, double* depth) const {
    double b, aor, ror, sigma, mest, mes, pdet, pwin;

    // Compute the duration; it will be zero if there is no transit.
    aor = get_a (period, mass) / radius;
    b = get_impact (aor, incl, e, omega);
    ror = rp * RADIUS_EARTH / radius;
    *duration = 24.0 * get_duration(aor, period, ror, b, incl, e, omega);
    if (*duration <= DBL_EPSILON) return 0.0;

    // Get the depth.
    *depth = get_depth(q1, q2, ror, b);
    if (*depth <= DBL_EPSILON) return 0.0;

    // Interpolate to get the CDPP at the correct duration.
    sigma = interp1d(*duration, cdpp_x_, cdpp_y_);
    mest = interp1d(*duration, thresh_x_, thresh_y_);

    // Compute the MES detection efficiency.
    mes = completeness_model_->get_mes(period, *depth, sigma, timefactor_);
    pdet = completeness_model_->get_pdet(period, mes, mest);

    // Get the window function.
    pwin = completeness_model_->get_pwin(period, dataspan_, dutycycle_);

    return pdet * pwin;
  };

  double sample_mass (random_state_t& state) const {
    boost::random::normal_distribution<> rng;
    return exp(ln_mass_ + sigma_ln_mass_ * rng(state));
  };

  double sample_radius (random_state_t& state) const {
    boost::random::normal_distribution<> rng;
    return exp(ln_radius_ + sigma_ln_radius_ * rng(state));
  };

private:
  double ln_mass_, sigma_ln_mass_, ln_radius_, sigma_ln_radius_,
         dataspan_, dutycycle_, timefactor_;
  std::vector<double> cdpp_x_, cdpp_y_, thresh_x_, thresh_y_;
  const CompletenessModel* completeness_model_;

  double interp1d (double x0, const std::vector<double>& x, const std::vector<double>& y) const {
    unsigned n = x.size();
    if (x0 <= x[0]) return y[0];
    for (unsigned i = 0; i < n-1; ++i)
      if (x[i] < x0 && x0 <= x[i+1])
        return (y[i+1]-y[i])/(x[i+1]-x[i])*(x0-x[i]) + y[i];
    return y[n-1];
  };
};

};  // namespace exoabc

#endif  // _EXOABC_COMPLETENESS_H_
