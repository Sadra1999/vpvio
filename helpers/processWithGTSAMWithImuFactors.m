function [T_wc_list_opt, landmarks_w_opt] = processWithGTSAMWithImuFactors(keyFrames, landmarks, K, g2oOptions)
if ismac
    addpath('/Users/valentinp/Research/gtsam_toolbox');
else
    addpath('~/Dropbox/Research/Ubuntu/gtsam_toolbox/');
end
 import gtsam.*;

%Add observations to the previous keyframe
for i = 2:length(keyFrames)
    prevKf = keyFrames(i-1);
    kf = keyFrames(i);
    [newLandmarkIds,idx] = setdiff(kf.landmarkIds, prevKf.landmarkIds);
     keyFrames(i-1).landmarkIds = [keyFrames(i-1).landmarkIds newLandmarkIds];
     keyFrames(i-1).pixelMeasurements = [keyFrames(i-1).pixelMeasurements kf.refPosePixels(:, idx)];
     keyFrames(i-1).predVectors = [keyFrames(i-1).predVectors kf.predVectors(:, idx)];
     
end


%Remove single observation landmarks (these will be all in the first
%keyframe)
allLandmarkIds = [];
for i = 1:length(keyFrames)
    kf = keyFrames(i);
    allLandmarkIds = [allLandmarkIds kf.landmarkIds];
end
[uniques,numUnique] = count_unique(allLandmarkIds);
singleObsLandmarkIds =  uniques(numUnique < 2);


%Remove all single observations in the first keyframe
for l_id = 1:length(keyFrames(1).landmarkIds)
   landmarkId = keyFrames(1).landmarkIds(l_id);
   if ismember(landmarkId, singleObsLandmarkIds)
        keyFrames(1).landmarkIds(l_id) = NaN;
        keyFrames(1).pixelMeasurements(:,l_id) = [NaN NaN]';
        keyFrames(1).predVectors(:,l_id) = NaN*ones(size(keyFrames(1).predVectors, 1),1);
        
        landmarks.position(:, landmarks.id == landmarkId) = [NaN NaN NaN]';
        landmarks.id(landmarks.id == landmarkId) = NaN;
   end
end

 keyFrames(1).pixelMeasurements(:, isnan(keyFrames(1).pixelMeasurements(1,:))) = [];
  keyFrames(1).predVectors(:, isnan(keyFrames(1).predVectors(1,:))) = [];

  keyFrames(1).landmarkIds(isnan(keyFrames(1).landmarkIds)) = [];
  
  
 landmarks.position(:, isnan(landmarks.position(1,:))) = [];
  landmarks.id(isnan(landmarks.id)) = [];


%Eliminate all crazy pixel errors
deleteObservations = []; 
landmarkIds_all = [];
pix_error_all = [];
for keyFrameNum = 1:length(keyFrames)
deleteObservations(keyFrameNum).deleteObs = [];

for l_id = 1:length(keyFrames(keyFrameNum).landmarkIds)
    landmarkId = keyFrames(keyFrameNum).landmarkIds(l_id);
    T_wk = keyFrames(keyFrameNum).T_wk;
    landmark_pos_w = landmarks.position(:,landmarks.id == landmarkId);
    landmark_pos_k = homo2cart(inv(T_wk)*[landmark_pos_w; 1]);
    pixel_coords = homo2cart(K*landmark_pos_k);
    true_pixel_coords = keyFrames(keyFrameNum).pixelMeasurements(:, l_id);
    pix_error = norm(pixel_coords - true_pixel_coords);
    landmarkIds_all = [landmarkIds_all landmarkId];
    
    if pix_error > g2oOptions.maxPixError
            deleteObservations(keyFrameNum).deleteObs(end+1) = l_id;
    else
          pix_error_all = [pix_error_all pix_error];
    end
end
end

totalDeletions = 0;
for kf = 1:length(deleteObservations)
    %Delete bad observations in this keyframe
    if ~isempty(deleteObservations(kf).deleteObs) 
        l_ids = deleteObservations(kf).deleteObs;
        keyFrames(kf).pixelMeasurements(:, l_ids) = [];
        keyFrames(kf).predVectors(:, l_ids) = [];
        keyFrames(kf).landmarkIds(l_ids) = [];
        totalDeletions = totalDeletions + length(l_ids);
    end
end
printf(['--------- \nDeleted ' num2str(totalDeletions) ' bad observations.\n---------\n']);


%Final cleanup: ensure there are no landmarks that have less than 2
%observations and remove any landmarks that are not in our good clusters

allLandmarkIds = [];
for i = 1:length(keyFrames)
    kf = keyFrames(i);
    allLandmarkIds = [allLandmarkIds kf.landmarkIds];
end
[uniques,numUnique] = count_unique(allLandmarkIds);
singleObsLandmarkIds =  uniques(numUnique < 3);
noObsLandmarkIds = setdiff(landmarks.id, uniques);
badLandmarkIds = union(singleObsLandmarkIds, noObsLandmarkIds);



% Create graph container and add factors to it
graph = NonlinearFactorGraph;

% add a constraint on the starting pose

%Extract intrinsics
f_x = K(1,1);
f_y = K(2,2);
c_x = K(1,3);
c_y = K(2,3);

% Create realistic calibration and measurement noise model
% format: fx fy skew cx cy baseline
K = Cal3_S2(f_x, f_y, 0, c_x, c_y);
%mono_model_r = noiseModel.Diagonal.Sigmas([3,3]');
%mono_model_l = noiseModel.Diagonal.Sigmas([0.1,0.1]');
mono_model_n = noiseModel.Diagonal.Sigmas([0.1,0.1]');


%landmarks struct:
% landmarks.id %1xN
% landmarks.position %3xN



% Create initial estimate for camera poses and landmarks
initialEstimate = Values;

kf = keyFrames(1);
R_wk = kf.R_wk;
t_kw_w = kf.t_kw_w;
currentPoseGlobal = Pose3(Rot3(R_wk), Point3(t_kw_w)); % initial pose is the reference frame (navigation frame)
currentVelocityGlobal = LieVector(keyFrames(1).imuDataStruct.v); 
currentBias = imuBias.ConstantBias(zeros(3,1), zeros(3,1));
sigma_init_x = noiseModel.Isotropic.Precisions([ 0.0; 0.0; 0.0; 1; 1; 1 ]);
sigma_init_v = noiseModel.Isotropic.Sigma(3, 1000.0);
sigma_init_b = noiseModel.Isotropic.Sigmas([ 0.100; 0.100; 0.100; 5.00e-05; 5.00e-05; 5.00e-05 ]);

IMU_metadata.AccelerometerBiasSigma = 0.000167;
IMU_metadata.GyroscopeBiasSigma = 2.91e-006;
sigma_between_b = [ IMU_metadata.AccelerometerBiasSigma * ones(3,1); IMU_metadata.GyroscopeBiasSigma * ones(3,1) ];
w_coriolis = [0;0;0];


%graph.add(PriorFactorPose3(1, currentPoseGlobal, sigma_init_x));
graph.add(PriorFactorLieVector(symbol('v',1), currentVelocityGlobal, sigma_init_v));
graph.add(PriorFactorConstantBias(symbol('b',1), currentBias, sigma_init_b));



for i = 1:length(keyFrames)
    kf = keyFrames(i);
    R_wk = kf.R_wk;
    t_kw_w = kf.t_kw_w;
    
    pixelMeasurements = kf.pixelMeasurements;
    landmarkIds = kf.landmarkIds;
    
    currPose = Pose3(Rot3(R_wk), Point3(t_kw_w));
    %Fix the first pose 
    if i < 3
         graph.add(NonlinearEqualityPose3(i, currPose));
    end

      currentVelKey =  symbol('v',i);
      currentBiasKey = symbol('b',i);
        currentPoseKey = i;
    if i > 1
        %Fix the first pose 
        % Summarize IMU data between the previous GPS measurement and now
        currentSummarizedMeasurement = gtsam.ImuFactorPreintegratedMeasurements( ...
      currentBias, 0.01.^2 * eye(3), ...
      0.000175.^2 * eye(3), 0 * eye(3));

      %Update measurements  
      accMeas = [kf.imuDataStruct.a ];
      omegaMeas = [kf.imuDataStruct.omega ];
      deltaT = kf.imuDataStruct.dt;
      currentSummarizedMeasurement.integrateMeasurement(accMeas, omegaMeas, deltaT);

    % Create IMU factor
    myImuFactor = ImuFactor( ...
      currentPoseKey-1, currentVelKey-1, ...
      currentPoseKey, currentVelKey, ...
      currentBiasKey, currentSummarizedMeasurement, [0 0 -9.81]', w_coriolis);
        graph.add(myImuFactor);
    
    poseIpred = Pose3;
    veliPred = LieVector;
    
    
    % Bias evolution as given in the IMU metadata
    graph.add(BetweenFactorConstantBias(currentBiasKey-1, currentBiasKey, imuBias.ConstantBias(zeros(3,1), zeros(3,1)), ...
      noiseModel.Diagonal.Sigmas(1 * sigma_between_b)));
  
        %delta = prevPose.between(currPose);
        %covariance = noiseModel.Diagonal.Sigmas([0.01; 0.01; 0.01; 0.000175; 0.000175; 0.000175]);
        %graph.add(BetweenFactorPose3(i-1,i, delta, covariance));
    end
    
    %prevPose = currPose;

    for j = 1:length(landmarkIds)
        if ~ismember(landmarkIds(j), badLandmarkIds) 
             graph.add(GenericProjectionFactorCal3_S2(Point2(double(pixelMeasurements(:,j))), mono_model_n, i, landmarkIds(j), K));

         end
    end
    
end
for i = 1:length(keyFrames)
    kf = keyFrames(i);
    R_wk = kf.R_wk;
    t_kw_w = kf.t_kw_w;

 %Print poses
    initialEstimate.insert(i, Pose3(Rot3(R_wk), Point3(t_kw_w)));
    initialEstimate.insert(symbol('v',i), LieVector(kf.imuDataStruct.v));
    initialEstimate.insert(symbol('b',i), currentBias);

end  
for i = 1:length(landmarks.id)
            if ~ismember(landmarks.id(i), badLandmarkIds)
                initialEstimate.insert(landmarks.id(i), Point3(double(landmarks.position(:,i))));
            end
end

% optimize
fprintf(1,'Optimizing\n'); tic
params = LevenbergMarquardtParams;
params.setMaxIterations(100);
params.setVerbosity('ERROR');
params.print('');
optimizer = LevenbergMarquardtOptimizer(graph, initialEstimate, params);
result = optimizer.optimize();
toc

T_wc_list_opt = zeros(4,4,length(keyFrames));
landmarks_w_opt = zeros(3, length(landmarks.id));

for i = 1:length(keyFrames)
    T_wc_list_opt(:,:,i) = result.at(i).matrix;
end  
landmarks_w_opt = [];
% 
% for i = 1:length(landmarks.id)
%                 if p~ismember(landmarks.id(i), singleObsLandmarkIds)
%     landmarks_w_ot(:,i) = result.at(landmarks.id(i)).vector;
%                 end
% end


end

