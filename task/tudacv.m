function [acc,acc_star,Ypred,Ypred_star] = tudacv(X,Y,T,options)
%
% Performs cross-validation of the TUDA model, which can be useful for
% example to compare different number or states or other parameters
% (the words decoder and state are used below indistinctly)
%
% INPUT
%
% X: Brain data, (time by regions)
% Y: Stimulus, (time by q); q is no. of stimulus features
%               For binary classification problems, Y is (time by 1) and
%               has values -1 or 1
%               For multiclass classification problems, Y is (time by classes) 
%               with indicators values taking 0 or 1. 
%           If the stimulus is the same for all trials, Y can have as many
%           rows as trials, e.g. (trials by q) 
% T: Length of series or trials
% options: structure with the training options - see documentation in
%                       https://github.com/OHBA-analysis/HMM-MAR/wiki
%  Apart from the options specified for tudatrain, these are specific to tudacv:
%  - options.CVmethod, This options establishes how to compute the model time
%                  courses in the held-out data. Note that it is not
%                  obvious which state to use in the held-out data, because
%                  deciding which one is the most appropriate needs to use Y,
%                  which is precisely what we aim to predict. Ways of
%                  estimating it in a non-circular way are:
%                  . options.CVmethod=1: the state time course in held-out trials 
%                  is taken to be the average from training. That is, if 20% of
%                  the training trials use decoder 1, and 80% use decoder 2,
%                  then the prediction in testing will be a weighted average of these  
%                  two decoders, with weights 0.8 and 0.2. 
%                  . options.CVmethod=2, the state time courses in testing are estimated 
%                  using just data and linear regression, i.e. we try to predict
%                  the state time courses in held-out trials using the data
%  - options.NCV, containing the number of cross-validation folds (default 10)
%  - options.lambda, regularisation penalty for estimating the testing
%  state time courses when options.CVmethod=2.
%  - options.c      an optional CV fold structure as returned by cvpartition
%
% OUTPUT
%
% acc: cross-validated explained variance if Y is continuous,
%           classification accuracy if Y is categorical (one value)
% acc_star: cross-validated accuracy across time (trial time by 1) 
% Ypred: predicted stimulus (trials by stimuli/classes)
% Ypred_star: predicted stimulus across time (time by trials by stimuli/classes)
%
% Author: Diego Vidaurre, OHBA, University of Oxford 
% Author: Cam Higgins, OHBA, University of Oxford  

N = length(T); q = size(Y,2); ttrial = T(1); K = options.K;
if ~all(T==T(1)), error('All elements of T must be equal for cross validation'); end 

if size(Y,1) == length(T) % one value per trial
    responses = Y;
else
    responses = reshape(Y,[ttrial N q]);
    responses = permute(responses(1,:,:),[2 3 1]); % N x q
end

options.Nfeatures = 0;
[X,Y,T,options] = preproc4hmm(X,Y,T,options); % this demeans Y if necessary
ttrial = T(1); p = size(X,2); q_star = size(Y,2);pstar = size(X,2);
Ycopy = Y; if q_star>q;Ycopy=Y(:,2:end);end %remove intercept term
classifier = options.classifier;
classification = ~isempty(classifier);
if classification, Ycopy = round(Ycopy); end

if q_star~=q && strcmp(options.distribution,'logistic')
    Ycopy = multinomToBinary(Ycopy);
    q = size(Ycopy,2);
end
if strcmp(classifier,'LDA') || options.encodemodel
    options.intercept = false; %this necessary to avoid double addition of intercept terms
end

if isfield(options,'CVmethod') 
    CVmethod = options.CVmethod; options = rmfield(options,'CVmethod');
else
    CVmethod = 1;
end
class_totals = (sum(Ycopy==1)./ttrial);
if q_star == (q+1)
    class_totals = class_totals(2:end); %remove intercept term
end 
if size(unique(class_totals))>1
    warning(['Note that Y is not balanced; ' ...
        'cross validation folds will not be balanced and predictions will be biased'])
end
if isfield(options,'c')
    NCV = options.c.NumTestSets;
    if isfield(options,'NCV'), options = rmfield(options,'NCV'); end
elseif isfield(options,'NCV')
    NCV = options.NCV; 
    options = rmfield(options,'NCV');
else
    %default to hold one-out CV unless NCV>10:
    NCV = max([0,class_totals]);
    if NCV > 10 || NCV < 1, NCV = 10; end
    
end
if isfield(options,'lambda') 
    lambda = options.lambda; options = rmfield(options,'lambda');
else, lambda = 0.0001; 
end
if isfield(options,'verbose') 
    verbose = options.verbose; options = rmfield(options,'verbose');
else, verbose = 1; 
end
options.verbose = 0; 

if ~isfield(options,'c')
    % this system is thought for cases where a trial can have more than 
    % 1 category, and potentially each column can have more than 2 values,
    % but there are not too many categories
    if classification 
        tmp = zeros(N,1);
        for j = 1:q
            rj = responses(:,j);
            uj = unique(rj);
            for jj = 1:length(uj)
                tmp(rj == uj(jj)) = tmp(rj == uj(jj)) + (q+1)^(j-1) * jj;
            end
        end
        uy = unique(tmp);
        group = zeros(N,1);
        for j = 1:length(uy)
            group(tmp == uy(j)) = j;
        end
        c2 = cvpartition(group,'KFold',NCV);
    else % Response is treated as continuous - no CV stratification
        c2 = cvpartition(N,'KFold',NCV);
    end
else
   c2 = options.c; options = rmfield(options,'c');
end
c = struct();
c.test = cell(NCV,1);
c.training = cell(NCV,1);
for icv = 1:NCV
    c.training{icv} = find(c2.training(icv));
    c.test{icv} = find(c2.test(icv));
end; clear c2

X = reshape(X,[ttrial N p]);
Y = reshape(Y,[ttrial N q_star]);
RidgePen = lambda * eye(p);

% Get Gamma and the Betas for each fold
Gammapred = zeros(ttrial,N,K); Betas = zeros(p,q_star,K,NCV); 
if strcmp(classifier,'LDA')
    LDAmodel = cell(NCV,1);
end
if strcmp(options.classifier,'regression'), options.classifier = ''; end
if options.encodemodel
    options.classifier = 'LDA';
    classifier = 'LDA';
    options = rmfield(options,'encodemodel');
end 
for icv = 1:NCV
    Ntr = length(c.training{icv}); Nte = length(c.test{icv});
    Xtrain = reshape(X(:,c.training{icv},:),[Ntr*ttrial p] ) ;
    Ytrain = reshape(Y(:,c.training{icv},:),[Ntr*ttrial q_star] ) ;
    Ttr = T(c.training{icv});
    [tuda,Gammatrain] = tudatrain(Xtrain,Ytrain,Ttr,options);
    if strcmp(classifier,'LDA')
        LDAmodel{icv} = tuda;
    else
        Betas(:,:,:,icv) = tudabeta(tuda);
    end    
    switch CVmethod
        case 1 % training average
            mGammatrain = squeeze(mean(reshape(Gammatrain,[ttrial Ntr K]),2)); 
            for j = 1:Nte, Gammapred(:,c.test{icv}(j),:) = mGammatrain; end
        case 2 % regression
            Xtest = permute(X(:,c.test{icv},:),[2 3 1]);
            Xtrain = permute(X(:,c.training{icv},:),[2 3 1]);
            Xtest = cat(2,Xtest,ones(Nte,1,ttrial)); %include intercept term
            Xtrain = cat(2,Xtrain,ones(Ntr,1,ttrial));
            RidgePen = lambda * eye(p+1);
            Gammatrain = permute(reshape(Gammatrain,[ttrial Ntr K]),[2 3 1]);
            for t = 1:ttrial
                B = (Xtrain(:,:,t)' * Xtrain(:,:,t) + RidgePen) \ ...
                    Xtrain(:,:,t)' * Gammatrain(:,:,t);
                pred = Xtest(:,:,t) * B;
                pred = pred - repmat(min(min(pred,[],2), zeros(Nte,1)),1,K);
                pred = pred ./ repmat(sum(pred,2),1,K);
                Gammapred(t,c.test{icv},:) = pred;
            end
        case 3 % distributional model
            Xtrain = reshape(X(:,c.training{icv},:),[ttrial*length(c.training{icv}),p]);
            Xtest = reshape(X(:,c.test{icv},:),[ttrial*length(c.test{icv}),p]);
            GammaTemp = fitEquivUnsupervisedModel(Xtrain,Gammatrain,Xtest,T(c.training{icv}),T(c.test{icv}));
            Gammapred(:,c.test{icv},:) = reshape(GammaTemp,[ttrial,length(c.test{icv}),K]);
    end      
    if verbose
        fprintf(['\nCV iteration: ' num2str(icv),' of ',int2str(NCV),'\n'])
    end
end

% Perform the prediction 
if strcmp(classifier,'LDA')
    Ypred = zeros(ttrial,N,q);
else
    Ypred = zeros(ttrial,N,q_star);
end
for icv = 1:NCV
    Nte = length(c.test{icv});
    Xtest = reshape(X(:,c.test{icv},:),[ttrial*Nte p]);
    Gammatest = reshape(Gammapred(:,c.test{icv},:),[ttrial*Nte K]);
    if strcmp(classifier,'LDA')
        predictions = LDApredict(LDAmodel{icv},Gammatest,Xtest,classification,var(Ytrain(:,1))==0);
        Ypred(:,c.test{icv},:) = reshape(predictions,[ttrial Nte q]);
    else %strcmp(classifier,'logistic')
        for k = 1:K
            sGamma = repmat(Gammatest(:,k),[1 q_star]);
            Ypred(:,c.test{icv},:) = Ypred(:,c.test{icv},:) + ...
                reshape( (Xtest * Betas(:,:,k,icv)) .* sGamma , [ttrial Nte q_star]);
        end
    end
end
if strcmp(options.distribution,'logistic')
    if length(unique(responses))==2 % denotes binary logistic regression
        Ypred = log_sigmoid(Ypred);
    else %multivariate logistic regression
        Ypred = multinomLogRegPred(Ypred);
    end
end

if classification
    Y = reshape(Ycopy,[ttrial*N q]);
    Y = continuous_prediction_2class(Ycopy,Y); % get rid of noise we might have injected 
    Ypred = reshape(Ypred,[ttrial*N q]);
    Ypred_star = reshape(continuous_prediction_2class(Ycopy,Ypred),[ttrial N q]);
    Ypred = zeros(N,q); 
    for j = 1:N % getting the most likely class for all time points in trial
        if q == 1 % binary classification, -1 vs 1
            Ypred(j) = sign(mean(Ypred_star(:,j,1)));
        else
           [~,cl] = max(mean(permute(Ypred_star(:,j,:),[1 3 2])));
           Ypred(j,cl) = 1; 
        end
    end
    % acc is cross-validated classification accuracy 
    Ypred_star = reshape(Ypred_star,[ttrial*N q]);
    if q == 1
        tmp = abs(Y - Ypred_star) < 1e-4;
    else
        tmp = sum(abs(Y - Ypred_star),2) < 1e-4;
    end
    acc = mean(tmp);
    acc_star = squeeze(mean(reshape(tmp, [ttrial N 1]),2));
else   
    Y = reshape(Ycopy,[ttrial*N q]);
    Ypred_star =  reshape(Ypred, [ttrial*N q]); 
    Ypred = permute( mean(Ypred,1) ,[2 3 1]);
    % acc is explained variance 
    acc = 1 - sum( (Y - Ypred_star).^2 ) ./ sum(Y.^2) ; 
    acc_star = zeros(ttrial,q); 
    Y = reshape(Y,[ttrial N q]);
    Ypred_star = reshape(Ypred_star, [ttrial N q]);
    for t = 1:ttrial
        y = permute(Y(t,:,:),[2 3 1]); 
        acc_star(t,:) = 1 - sum((y - permute(Ypred_star(t,:,:),[2 3 1])).^2) ./ sum(y.^2);
    end
    Ypred_star = reshape(Ypred_star, [ttrial*N q]);
end
    
end


function Y_out = multinomToBinary(Y_in)
Y_out=zeros(length(Y_in),length(unique(Y_in)));
for i=1:length(Y_in)
    Y_out(i,Y_in(i))=1;
end
end

