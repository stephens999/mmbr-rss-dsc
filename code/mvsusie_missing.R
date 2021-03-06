# ---- mvsusie_missing ----


## this is a simplified implementation for mvSuSiE with missing data in Y
## prior_variance is a matrix
## prior_variance and residual_variance are fixed in the algorithm.

## If compute_objective = TRUE, the stopping criteria is based on elbo;
## otherwise, it is based on changes in pip.
library(abind)
library(susieR)
mvsusie_missing = function(X, Y, L=10, prior_variance, residual_variance, approximate=FALSE, intercept = TRUE,
                           max_iter = 100, prior_weights=NULL, tol=1e-3, min_abs_corr=0.5, prior_tol=1E-9,
                           compute_objective = FALSE){
  if (is.null(dim(Y))) Y <- matrix(Y,length(Y),1)
  R <- ncol(Y)
  N <- nrow(Y)
  J <- ncol(X)
  Y_missing <- is.na(Y)
  Y_non_missing <- !Y_missing
  # store missing pattern, TRUE for observe, FALSE for missing
  missing_pattern <- unique(Y_non_missing)
  Y_missing_pattern_assign <- numeric(N)
  for(k in 1:nrow(missing_pattern)){
    idx = which(apply(Y_non_missing, 1, function(x) identical(x, missing_pattern[k,])))
    Y_missing_pattern_assign[idx] <- k
  }
  Y[Y_missing] <- 0
  if(approximate){
    X_for_Y_missing <- array(X, dim = c(N, J, R))
    for(r in 1:R) {
      X_for_Y_missing[Y_missing[,r],,r] <- NA
    }
  }else{
    X_for_Y_missing <- outer(X,  diag(R)) # N by J by R by R
  }

  ## compute inverse of residual variance for each missing pattern
  residual_variance_inv <- list()
  residual_variance_eigen <- list()
  for(k in 1:nrow(missing_pattern)){
    if(R == 1){
      residual_variance_inv[[k]] <- missing_pattern[k,] / residual_variance
      if(sum(missing_pattern[k,])>0){
        residual_variance_eigen[[k]] <- residual_variance
      }else{
        residual_variance_eigen[[k]] <- numeric(0)
      }
    }else{
      residual_variance_inv[[k]] <- matrix(0, R, R)
      if(sum(missing_pattern[k,])>0){
        Vk = residual_variance[which(missing_pattern[k,]), which(missing_pattern[k,])]
        eigenVk <- eigen(Vk, symmetric = TRUE)
        dinv <- 1/(eigenVk$values)
        residual_variance_eigen[[k]] <- eigenVk$values
        residual_variance_inv[[k]][which(missing_pattern[k,]), which(missing_pattern[k,])] <- eigenVk$vectors %*% (dinv * t(eigenVk$vectors))
      }else{
        residual_variance_eigen[[k]] <- numeric(0)
      }
    }
  }

  ## centering
  if(intercept){
    if(approximate){
      cm_x <- colMeans(X_for_Y_missing, na.rm=T) # J by R
      Xbar = cm_x
      for(r in 1:R){
        X_for_Y_missing[,,r] <- t(t(X_for_Y_missing[,,r]) - cm_x[,r])
        X_for_Y_missing[,,r][is.na(X_for_Y_missing[,,r])] <- 0
      }
      if (R == 1) Y_mean <- mean(Y[Y_non_missing])
      else Y_mean <- sapply(1:R, function(r) mean(Y[Y_non_missing[,r],r]))
      Y <- t(t(Y) - Y_mean)
      Y[!Y_non_missing] <- 0
    }else{
      # sum_i V_i^{-1} R by R matrix
      Vinvsum = Reduce('+', lapply(1:nrow(missing_pattern), function(i)
        residual_variance_inv[[i]] * sum(Y_missing_pattern_assign == i)))
      Vinvsuminv <- invert_via_chol(Vinvsum)

      # sum_i V_i^{-1} y_i R by 1 matrix
      Ysum = Reduce('+', lapply(1:N, function(i)
        residual_variance_inv[[Y_missing_pattern_assign[i]]] %*% Y[i,] ))

      # center Y
      Y_mean <- as.numeric(Vinvsuminv %*% Ysum)
      Y <- t(t(Y) - Y_mean)
      Y[!Y_non_missing] <- 0

      # center X
      Xbar <- array(0, dim=c(J, R, R))
      for(j in 1:J){
        # For variant j, Vinvsuminv sum_i V_i^{-1} X_{i,j} R by R matrix
        Xbar[j,,] <- Vinvsuminv %*% Reduce('+', lapply(1:N, function(i) residual_variance_inv[[Y_missing_pattern_assign[i]]] * X[i,j]) )
        X_for_Y_missing[,j,,] <- sweep(X_for_Y_missing[,j,,,drop=F], 3:4, Xbar[j,,])
      }
    }
  }

  svs_inv <- list()
  for(j in 1:J){
    # For variant j, sum_i X_for_Y_missing[i,j,,]^T V_i^{-1} X_for_Y_missing[i,j,,], R by R matrix
    # when there is no missing, it is sum(x_j^2) * V^{-1}
    if(approximate){
      svs_inv[[j]] <- Reduce('+', lapply(1:N, function(i) t(residual_variance_inv[[Y_missing_pattern_assign[i]]] *
                                                                 X_for_Y_missing[i,j,]) * X_for_Y_missing[i,j,]))
    }else{
      svs_inv[[j]] <- Reduce('+', lapply(1:N, function(i) crossprod(X_for_Y_missing[i,j,,],
                                             residual_variance_inv[[Y_missing_pattern_assign[i]]] %*%
                                             X_for_Y_missing[i,j,,])))
    }
  }
  s = init(N, J, R, L, prior_variance, prior_weights)
  s$R = Y
  pip_history = list()
  if(compute_objective){
    elbo = c()
  }else{
    elbo = NA
  }
  for(i in 1:max_iter){
    s = update_each_effect(X, Xbar, X_for_Y_missing, Y, s, Y_missing_pattern_assign, residual_variance_inv, svs_inv, compute_objective)
    pip_history[[i]] = s$alpha
    if(compute_objective){
      elbo = c(elbo, get_elbo(s, Xbar, X, X_for_Y_missing, Y, Y_missing_pattern_assign, residual_variance_eigen, residual_variance_inv))
    }
    if(i > 1){
      if(compute_objective){
        if((elbo[i]-elbo[i-1])<tol) {
          s$niter = i
          break;
        }
      }else{
        delta = max(abs(apply(1 - pip_history[[i]], 2, prod) - apply(1 - pip_history[[i-1]], 2, prod)))
        if(delta < tol){
          s$niter = i
          s$delta = delta
          break
        }
      }
    }
  }
  s$elbo = elbo
  s$null_index = -9
  s$V = 1
  s$sets = susie_get_cs(s, X=X, min_abs_corr=min_abs_corr)
  s$pip = susie_get_pip(s, prior_tol=prior_tol)
  return(s)
}

update_each_effect = function(X, Xbar, X_for_Y_missing, Y, s, Y_missing_pattern_assign, residual_variance_inv, svs_inv, compute_objective) {
  # Repeat for each effect to update.
  L = nrow(s$alpha)
  if (L > 0)
    for (l in 1:L) {

      # # Remove lth effect from fitted values.
      # s$Xr = s$Xr - compute_Xb(Xbar, X, X_for_Y_missing, s$alpha[l,] * s$mu[l,,])
      #
      # # Compute residuals.
      # R = Y - s$Xr
      s$R = s$R + compute_Xb(Xbar, X, X_for_Y_missing, s$alpha[l,] * s$mu[l,,])

      res = SER(X, X_for_Y_missing,Xbar,s$R,Y_missing_pattern_assign,residual_variance_inv,svs_inv, s$prior, s$prior_weights)

      # Update the variational estimate of the posterior mean.
      s$alpha[l,]  = res$alpha
      s$mu[l,,]    = res$mu1
      s$mu2[l,,,]   = res$mu2
      s$lbf[l]     = res$lbf_model
      if(compute_objective){
        if (length(dim(res$mu2)) == 3) {
          pb2 = lapply(1:nrow(res$mu1), function(j) res$alpha[j] * res$mu2[j,,])
        } else {
          pb2 = lapply(1:nrow(res$mu1), function(j) res$alpha[j] * matrix(res$mu2[j,]))
        }
        Xb = compute_Xb(Xbar, X, X_for_Y_missing, s$alpha[l,] * s$mu[l,,])
        E1 = sum(sapply(1:nrow(Y), function(i) crossprod(s$R[i,], residual_variance_inv[[Y_missing_pattern_assign[i]]] %*% Xb[i,])))
        s$vbxxb[l] = sum(sapply(1:length(pb2), function(j) tr(svs_inv[[j]] %*% pb2[[j]])))
        s$kl[l] = E1 - (s$vbxxb[l] / 2) - res$lbf_model
      }
      # s$Xr = s$Xr + compute_Xb(Xbar, X, X_for_Y_missing, s$alpha[l,] * s$mu[l,,])
      s$R = s$R - compute_Xb(Xbar, X, X_for_Y_missing, s$alpha[l,] * s$mu[l,,])
    }
  return(s)
}

SER = function(X, X_for_Y_missing, Xbar, Y, Y_missing_pattern_assign, residual_variance_inv, svs_inv, prior, prior_weights = NULL){
  J = dim(X_for_Y_missing)[2]
  if (is.null(prior_weights))
    prior_weights = rep(1/J,J)
  XtY = compute_XtY(X, X_for_Y_missing,Y,Y_missing_pattern_assign, residual_variance_inv, Xbar)
  post = multivariate_regression(XtY, svs_inv, prior)
  lbf = post$lbf
  maxlbf = max(lbf)
  # w is proportional to BF, but subtract max for numerical stability.
  w = exp(lbf - maxlbf)
  # Posterior prob for each SNP.
  w_weighted = w * prior_weights
  weighted_sum_w = sum(w_weighted)
  alpha = w_weighted / weighted_sum_w
  lbf_model = maxlbf + log(weighted_sum_w)
  return(list(alpha = alpha,mu1 = post$b1 , mu2 = post$b2 , lbf = lbf,
              lbf_model = lbf_model))
}

multivariate_regression = function(XtY, svs_inv, U) {
  post_cov = lapply(1:length(svs_inv), function(j) U %*% solve(diag(nrow(U)) + svs_inv[[j]] %*% U))
  lbf = sapply(1:length(svs_inv), function(j) -0.5 * log(det(diag(nrow(U)) + svs_inv[[j]] %*% U)) + 0.5*t(XtY[j,])%*%(post_cov[[j]]%*%XtY[j,]))
  lbf[which(is.nan(lbf))] = 0
  post_b1 = t(do.call(cbind, lapply(1:length(svs_inv), function(j) post_cov[[j]] %*% XtY[j,]))) # J by R
  post_b2 = lapply(1:length(post_cov), function(j) tcrossprod(post_b1[j,]) + post_cov[[j]]) # length J list with R by R matrix
  # deal with degerated case with 1 condition
  if (ncol(post_b1) == 1) {
    post_b2 = matrix(unlist(post_b2), length(post_b2), 1)
  } else {
    post_b2 = aperm(abind(post_b2, along = 3), c(3,1,2)) # J by R by R
  }
  return(list(b1 = post_b1, b2 = post_b2, lbf = lbf, cov = post_cov))
}

get_elbo = function(s, Xbar, X, X_for_Y_missing, Y, Y_missing_pattern_assign, residual_variance_eigenvalues, residual_variance_inv){
  N = length(Y_missing_pattern_assign)
  Y_missing_assign =  table(Y_missing_pattern_assign)
  expected_loglik = -0.5 * log(2*pi) * sum(sapply(residual_variance_eigenvalues, length) * Y_missing_assign) -
    0.5 * sum(sapply(residual_variance_eigenvalues, function(x) ifelse(length(x)>0,sum(log(x)),0)) * Y_missing_assign)
  E1 = sapply(1:nrow(s$alpha), function(l){
    Xb = compute_Xb(Xbar, X, X_for_Y_missing,s$alpha[l,] * s$mu[l,,])
    sum(sapply(1:N, function(i) crossprod(Xb[i,], residual_variance_inv[[Y_missing_pattern_assign[i]]] %*% Xb[i, ])  ))
  })
  E1 = sum(sapply(1:N, function(i) crossprod(s$R[i,],residual_variance_inv[[Y_missing_pattern_assign[i]]] %*% s$R[i,]) )) - sum(E1)
  essr = E1 + sum(s$vbxxb)
  expected_loglik - 0.5 * essr - sum(s$kl)
}

## utils
invert_via_chol = function(x) {
  if (all(x==0)) return(x)
  return(chol2inv(muffled_chol(x)))
}

muffled_chol = function(x, ...){
  withCallingHandlers(chol(x, ...),
                      warning = function(w) {
                        if (grepl("the matrix is either rank-deficient or indefinite", w$message))
                          invokeRestart("muffleWarning")
                      })
}

compute_XtY = function(X, X_for_Y_missing,Y,Y_missing_pattern_assign,residual_variance_inv, Xbar){ # J by R
  N = dim(X_for_Y_missing)[1]
  J = dim(X_for_Y_missing)[2]
  VinvY <- t(sapply(1:N, function(i) residual_variance_inv[[Y_missing_pattern_assign[i]]] %*% Y[i,])) # N by R
  if(length(dim(X_for_Y_missing)) == 3){ ## approximate
    XtY <- t(sapply(1:J, function(j) colSums(X_for_Y_missing[,j,] * VinvY) ))
  }else{
    XtY <- t(sapply(1:J, function(j) colSums(X[,j] * VinvY) - crossprod(Xbar[j,,], colSums(VinvY)) ))
  }
  if (nrow(XtY) != J) XtY <- t(XtY)
  return(XtY)
}

init = function(N, J, R, L, U, prior_weights){
  if(is.null(prior_weights))
    prior_weights = rep(1/J,J)
  else
    prior_weights = prior_weights / sum(prior_weights)

  s = list(alpha  = matrix(1/J, L, J),
           mu     = array(0,dim = c(L, J, R)),
           mu2    = array(0,dim = c(L, J, R, R)),
           Xr     = matrix(0,N, R),
           prior      = U,
           prior_weights = prior_weights,
           kl = numeric(L),
           vbxxb = numeric(L),
           R = matrix(0,N, R))
  class(s) = 'susie'
  return(s)
}

compute_Xb = function(Xbar, X, X_for_Y_missing, b){
  if(is.vector(b)){
    b = matrix(b, length(b),1)
  }
  if(length(dim(X_for_Y_missing)) == 3){
    Xb = sapply(1:ncol(b), function(r) X_for_Y_missing[,,r] %*% b[,r])
  }else{
    Xbarb = Reduce('+', lapply(1:ncol(X), function(j) Xbar[j,,] %*% b[j,]))
    Xb = X %*% b - matrix(Xbarb, nrow(X), ncol(b), byrow = TRUE)
  }
  return(Xb)
}

tr = function (m) {
  if (!is.matrix(m) | (dim(m)[1] != dim(m)[2]))
    stop("Input to tr() function must be a square matrix")
  return(sum(diag(m), na.rm = TRUE))
}


