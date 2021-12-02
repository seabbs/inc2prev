functions {
#include gaussian_process.stan
#include rt.stan
#include prev.stan
#include ab.stan
#include generated_quantities.stan
}

data {
  int ut; // initial period (before data starts)
  int t; // number of time points to model
  int obs; // number of prevalence observations
  int ab_obs; // number of antibody prevalence observations
  vector[obs] prev; // observed positivity prevalence
  vector[obs] prev_sd2; // squared standard deviation of observed positivity prevalence
  vector[ab_obs] ab; // observed antibody posivitiy prevalence
  vector[ab_obs] ab_sd2; // squared standard deviation of observed antibody prevalence
  int prev_stime[obs]; // starting times of positivity prevalence observations
  int prev_etime[obs]; // end times of positivity prevalence observations
  int ab_stime[ab_obs]; // starting times of antibody prevalence observations
  int ab_etime[ab_obs]; // end times of antibody prevalence observations
  real vacc[t]; // vaccinations
  int pbt; // maximum detection time
  vector[pbt] prob_detect_mean; // at each time since infection, probability of detection
  vector[pbt] prob_detect_sd; // at each time since infection, tandard deviation of probability of detection
  real lengthscale_alpha; // alpha for gp lengthscale prior
  real lengthscale_beta;  // beta for gp lengthscale prior
  int <lower = 1> M; // approximate gp dimensions
  real L; // approximate gp boundary
  real gtm[2]; // mean and standard deviation (sd) of the mean generation time
  real gtsd[2]; // mean and sd of the sd of the generation time
  int gtmax; // maximum number of days to consider for the generation time
  real inc_zero; // number of infections at time zero
  real init_ab_mean; // mean estimate of initial antibody prevalence
  real init_ab_sd;   // sd of estimate of initial antibody prevalence
}

transformed data {
  // set up approximate gaussian process
  matrix[t, M] PHI = setup_gp(M, L, t);
}

parameters {
  real<lower = 0> rho; // length scale of gp
  real<lower = 0> alpha; // scale of gp
  vector[M] eta; // eta of gp
  real<lower = 0> sigma; // observation error
  real<lower = 0> ab_sigma; // observation error
  vector<lower = 0, upper = 1>[pbt] prob_detect; // probability of detection as a function of time since infection
  real<lower = 0, upper = 1> beta; // proportion that don't seroconvert
  real<lower = 0, upper = 1> gamma; // daily rate of antibody waning
  real<lower = 0, upper = 1> delta; // vaccine efficacy
  real<lower = 0, upper = 1> init_dab; // initial proportion with antibodies
}

transformed parameters {
  vector[t] gp; // value of gp at time t
  vector[t] infections; // incident infections at time t
  vector[t] dcases; // detectable cases at time t
  vector[t] dab; // proportion of individuals with antibodies at time t
  vector[obs] odcases;
  vector[ab_obs] odab;
  vector[obs] combined_sigma;
  vector[ab_obs] combined_ab_sigma;
  // update gaussian process
  gp = update_gp(PHI, M, L, alpha, rho, eta, 0);
  // relative probability of infection
  infections = inv_logit(inc_zero + gp);
  // calculate detectable cases
  dcases = detectable_cases(infections, prob_detect, pbt, t);
  // calculate observed detectable cases
  odcases = observed_cases(dcases, prev_stime, prev_etime, ut, obs);
  // calculate detectable antibodies
  dab = detectable_antibodies(infections, vacc, beta, gamma, delta, init_dab, t);
  // calculate observed detectable antibodies
  odab = observed_cases(dab, ab_stime, ab_etime, ut, ab_obs);
  //combined standard error
  combined_sigma = sqrt(square(sigma) + prev_sd2);
  combined_ab_sigma = sqrt(square(ab_sigma) + ab_sd2);

}

model {
  // gaussian process priors
  rho ~ inv_gamma(lengthscale_alpha, lengthscale_beta);
  alpha ~ std_normal() T[0,];
  eta ~ std_normal();

  // prevalence observation model
  for (i in 1:pbt) {
    prob_detect[i] ~ normal(prob_detect_mean[i], prob_detect_sd[i]) T[0, 1];
  }
  sigma ~ normal(0.005, 0.0025) T[0,];
  ab_sigma ~ normal(0.005, 0.0025) T[0,];
  prev ~ normal(odcases, combined_sigma);
  ab ~ normal(odab, combined_ab_sigma);
  init_dab ~ normal(init_ab_mean, init_ab_sd);
}

generated quantities {
  vector[t - ut] R;
  vector[t - 1] r;
  real est_prev[obs];
  real est_ab[obs];
 // sample estimated prevalence
  est_prev = normal_rng(odcases, combined_sigma);
  est_ab = normal_rng(odab, combined_ab_sigma);
  // sample generation time
  real gtm_sample = normal_rng(gtm[1], gtm[2]);
  real gtsd_sample = normal_rng(gtsd[1], gtsd[2]);
  // calculate Rt using infections and generation time
  R = calculate_Rt(infections, ut, gtm_sample, gtsd_sample, gtmax, 1);
  // calculate growth
  r = calculate_growth(infections, 1);
}