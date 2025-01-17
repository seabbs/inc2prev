% Generated by roxygen2: do not edit by hand
% Please edit documentation in R/utils.R
\name{expose_stan_fns}
\alias{expose_stan_fns}
\title{Expose Stan functions}
\usage{
expose_stan_fns(files, target_dir, ...)
}
\arguments{
\item{files}{Stan files containing functions to expose}

\item{target_dir}{Directory containing Stan files}

\item{...}{Additional arguments passed to
\code{\link{rstan::expose_stan_functions}}}
}
\value{
NULL (invisible)
}
\description{
Exposes stan functions to R
}
\seealso{
Other utils: 
\code{\link{inv_logit}()},
\code{\link{logit}()}
}
\concept{utils}
