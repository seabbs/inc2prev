// Probability of detection using a piecewise linear with a single breakpoint
// on a logit scale
// Based on: https://doi.org/10.1186/s12916-021-01982-x
vector detection_prob(int days, vector effs, real bp) {
  vector[days] pb;
  vector[days] k;
  for (i in 1:(days)) {
    k[i] = i - 0.5; // Probability at halfway point of the day
  }
  k = k - bp; // centre on breakpoint
  for (i in 1:days) {
    pb[i] = effs[1] + effs[2] * k[i] + k[i] * effs[3] * effs[2] * step(k[i]);
  }
  pb = inv_logit(pb);
  return(pb);
}