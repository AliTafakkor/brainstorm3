function OutputFiles = bst_connectivity(FilesA, FilesB, OPTIONS)
% BST_CONNECTIVITY: Computes a connectivity metric between two files A and B
%
% USAGE:  OutputFiles = bst_connectivity(FilesA, FilesB, OPTIONS)
%             OPTIONS = bst_connectivity()

% @=============================================================================
% This function is part of the Brainstorm software:
% https://neuroimage.usc.edu/brainstorm
% 
% Copyright (c) University of Southern California & McGill University
% This software is distributed under the terms of the GNU General Public License
% as published by the Free Software Foundation. Further details on the GPLv3
% license can be found at http://www.gnu.org/copyleft/gpl.html.
% 
% FOR RESEARCH PURPOSES ONLY. THE SOFTWARE IS PROVIDED "AS IS," AND THE
% UNIVERSITY OF SOUTHERN CALIFORNIA AND ITS COLLABORATORS DO NOT MAKE ANY
% WARRANTY, EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO WARRANTIES OF
% MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE, NOR DO THEY ASSUME ANY
% LIABILITY OR RESPONSIBILITY FOR THE USE OF THIS SOFTWARE.
%
% For more information type "brainstorm license" at command prompt.
% =============================================================================@
%
% Authors: Francois Tadel, 2012-2022
%          Martin Cousineau, 2017
%          Hossein Shahabi, 2019-2020
%          Daniele Marinazzo, 2022


%% ===== DEFAULT OPTIONS =====
Def_OPTIONS.Method        = 'corr';
Def_OPTIONS.ProcessName   = '';
Def_OPTIONS.TargetA       = [];
Def_OPTIONS.TargetB       = [];
Def_OPTIONS.Freqs         = 0;
Def_OPTIONS.TimeWindow    = [];
Def_OPTIONS.IgnoreBad     = 0;             % For recordings: Ignore bad channels
Def_OPTIONS.ScoutFunc     = 'all';         % Scout function {mean, max, pca, std, all}
Def_OPTIONS.ScoutTime     = 'before';      % When to apply scout function: {before, after}
Def_OPTIONS.RemoveMean    = 1;             % Option for Correlation
Def_OPTIONS.CohMeasure    = 'mscohere';    % {'mscohere'=Magnitude-square, 'icohere'=Imaginary, 'icohere2019', 'lcohere2019'}
Def_OPTIONS.WinLen        = [];            % Option for spectral estimates (Coherence 2021)
Def_OPTIONS.MaxFreqRes    = [];            % Option for spectral estimates (Coherence - deprecated, spectral Granger)
Def_OPTIONS.MaxFreq       = [];            % Option for spectral estimates (Coherence, spectral Granger)
Def_OPTIONS.CohOverlap    = 0.50;          % Option for Coherence
Def_OPTIONS.GrangerOrder  = 10;            % Option for Granger causality
Def_OPTIONS.GrangerDir    = 'out';         % Option for Granger causality
Def_OPTIONS.RemoveEvoked  = 0;             % Removed evoked response to each single trial (useful to bring signals closer to a stationnary state)
Def_OPTIONS.isMirror      = 1;             % Option for PLV
Def_OPTIONS.PlvMeasure    = 'magnitude';   % Option for PLV
Def_OPTIONS.isSymmetric   = [];            % Optimize processing and storage for simple matrices
Def_OPTIONS.pThresh       = 0.05;          % Significativity threshold for the metric
Def_OPTIONS.OutputMode    = 'input';       % {'avg','input','concat','avgcoh'}
Def_OPTIONS.iOutputStudy  = [];
Def_OPTIONS.isSave        = 1;
% Return the default options
if (nargin == 0)
    OutputFiles = Def_OPTIONS;
    return
end


%% ===== INITIALIZATIONS =====
% Parse inputs
if ischar(FilesA)
    FilesA = {FilesA};
end
if ischar(FilesB) && ~isempty(FilesB)
    FilesB = {FilesB};
end
% Copy default options to OPTIONS structure (do not replace defined values)
OPTIONS = struct_copy_fields(OPTIONS, Def_OPTIONS, 0);
% Initialize output variables
OutputFiles = {};
AllComments = {};
Ravg = [];
nAvg = 0;
nTime = 1;
% Initialize progress bar
if bst_progress('isVisible')
    startValue = bst_progress('get');
else
    startValue = 0;
end
% If only one file: process as only one file (no concatenation, no average removal)
if (length(FilesA) == 1)
    OPTIONS.OutputMode = 'input';
    OPTIONS.RemoveEvoked = 0;
end
% Frequency bands
if iscell(OPTIONS.Freqs)
    FreqBands = OPTIONS.Freqs;
else
    FreqBands = [];
end
% Frequency limits: 0 = disable
if isequal(OPTIONS.MaxFreq, 0)
    OPTIONS.MaxFreq = [];
end
% Frequency max resolution: 0 = error
if (isempty(OPTIONS.MaxFreqRes) || (OPTIONS.MaxFreqRes <= 0)) && isempty(OPTIONS.WinLen) && ismember(OPTIONS.Method, {'cohere', 'spgranger'})
    bst_report('Error', OPTIONS.ProcessName, [], 'Invalid frequency resolution.');
    return;
end
% Symmetric storage?
if isempty(OPTIONS.isSymmetric)
    OPTIONS.isSymmetric = any(strcmpi(OPTIONS.Method, {'corr','cohere','plv','plvt','ciplv','ciplvt','wpli','wplit','aec','henv'})) && (isempty(FilesB) || (isequal(FilesA, FilesB) && isequal(OPTIONS.TargetA, OPTIONS.TargetB)));
end
% Processing [1xN] or [NxN]
isConnNN = isempty(FilesB);
% Options for LoadInputFile(), for FilesA and FilesB separately
LoadOptionsA.IgnoreBad   = OPTIONS.IgnoreBad;  % From data files: KEEP the bad channels
LoadOptionsA.ProcessName = OPTIONS.ProcessName;
if strcmpi(OPTIONS.ScoutTime, 'before')
    LoadOptionsA.TargetFunc = OPTIONS.ScoutFunc;
else
    LoadOptionsA.TargetFunc = 'All';
end
% Load kernel-based results as kernel+data for coherence ONLY
LoadOptionsA.LoadFull = ~isempty(OPTIONS.TargetA)  || ~ismember(OPTIONS.Method, {'cohere'});  
LoadOptionsB = LoadOptionsA;
LoadOptionsB.LoadFull = ~isempty(OPTIONS.TargetB) || ~ismember(OPTIONS.Method, {'cohere'});
% Use the signal processing toolbox?
if bst_get('UseSigProcToolbox')
    hilbert_fcn = @hilbert;
else
    hilbert_fcn = @oc_hilbert;
end


%% ===== CONCATENATE INPUTS / REMOVE AVERAGE =====
sAverageA = [];
sAverageB = [];
nTrials = 1;
% How to read the files
switch (OPTIONS.OutputMode)
    case 'concat',  isConcat = 1;
    case 'avgcoh',  isConcat = 2;
    otherwise,      isConcat = 0;
end

% === LOAD CALLS ONLY ===
% Prepare load calls, data will be loaded in bst_cohn_2021
if strcmpi(OPTIONS.OutputMode, 'avgcoh') && ~OPTIONS.RemoveEvoked
    % Number of concatenated trials to process
    nTrials = length(FilesA);
    % Load first FileA, for getting all the file metadata
    sInputA = bst_process('LoadInputFile', FilesA{1}, OPTIONS.TargetA, OPTIONS.TimeWindow, LoadOptionsA);
    if (size(sInputA.Data,2) < 2)
        bst_report('Error', OPTIONS.ProcessName, FilesA{1}, 'Invalid time selection, check the input time window.');
        return;
    end
    % FilesA load calls
    sInputA.Data = cell(1, nTrials);
    for iFile = 1:nTrials
        sInputA.Data{iFile} = {@bst_process, 'LoadInputFile', FilesA{iFile}, OPTIONS.TargetA, OPTIONS.TimeWindow, LoadOptionsA};
    end
    FilesA = FilesA(1);
    % FilesB load calls
    if ~isConnNN
        % Load first FileA, for getting all the file metadata
        sInputB = bst_process('LoadInputFile', FilesB{1}, OPTIONS.TargetB, OPTIONS.TimeWindow, LoadOptionsB);
        if (size(sInputB.Data,2) < 2)
            bst_report('Error', OPTIONS.ProcessName, FilesB{1}, 'Invalid time selection, check the input time window.');
            return;
        end
        % FilesB load calls
        sInputB.Data = cell(1, nTrials);
        for iFile = 1:nTrials
            sInputB.Data{iFile} = {@bst_process, 'LoadInputFile', FilesB{iFile}, OPTIONS.TargetB, OPTIONS.TimeWindow, LoadOptionsB};
        end
        FilesB = FilesB(1);
    else
        sInputB = sInputA;
    end

% === LOAD AND CONCATENATE ===
% Load all the data and concatenate it
elseif (isConcat >= 1)
    bst_progress('text', 'Loading input files...');
    % Number of concatenated trials to process
    nTrials = length(FilesA);
    % Concatenate FileA
    sInputA = LoadAll(FilesA, OPTIONS.TargetA, OPTIONS.TimeWindow, LoadOptionsA, isConcat, OPTIONS.RemoveEvoked, startValue);
    if isempty(sInputA)
        bst_report('Error', OPTIONS.ProcessName, FilesA, 'Could not calculate the average of input files A: the number of signals of all the files must be identical.');
        return;
    end
    FilesA = FilesA(1);
    % Concatenate FileB
    if ~isConnNN
        sInputB = LoadAll(FilesB, OPTIONS.TargetB, OPTIONS.TimeWindow, LoadOptionsB, isConcat, OPTIONS.RemoveEvoked, startValue);
        if isempty(sInputB)
            bst_report('Error', OPTIONS.ProcessName, FilesB, 'Could not calculate the average of input files B: the number of signals of all the files must be identical.');
            return;
        end
        FilesB = FilesB(1);
        % Some quality check
        if (size(sInputA.Data,2) ~= size(sInputB.Data,2))
            bst_report('Error', OPTIONS.ProcessName, {FilesA{:}, FilesB{:}}, 'Files A and B must have the same number of time samples.');
            return;
        end
    else
        sInputB = sInputA;
    end

% === LOAD AND REMOVE AVERAGE ===
elseif OPTIONS.RemoveEvoked
    % Average: Files A
    [tmp, sAverageA] = LoadAll(FilesA, OPTIONS.TargetA, OPTIONS.TimeWindow, LoadOptionsA, 0, 1, startValue);
    if isempty(sAverageA)
        bst_report('Error', OPTIONS.ProcessName, FilesA, 'Could not calculate the average of input files A: the dimensions of all the files must be identical.');
        return;
    end
    % Average: Files B
    if ~isConnNN
        [tmp, sAverageB] = LoadAll(FilesB, OPTIONS.TargetB, OPTIONS.TimeWindow, LoadOptionsB, 0, 1, startValue);
        if isempty(sAverageB)
            bst_report('Error', OPTIONS.ProcessName, FilesB, 'Could not calculate the average of input files B: the dimensions of all the files must be identical.');
            return;
        end
    end
end
if isConnNN
    FilesB = FilesA;
end 
OPTIONS.isScoutA = ~isempty(OPTIONS.TargetA) && (isstruct(OPTIONS.TargetA) || iscell(OPTIONS.TargetA));
OPTIONS.isScoutB = ~isempty(OPTIONS.TargetB) && (isstruct(OPTIONS.TargetB) || iscell(OPTIONS.TargetB));


%% ===== CALCULATE CONNECTIVITY =====
% Loop over input files
for iFile = 1:length(FilesA)
    bst_progress('set',  round(startValue + (iFile-1) / length(FilesA) * 100));
    %% ===== LOAD SIGNALS =====
    if ismember(OPTIONS.OutputMode, {'avg','input'})
        bst_progress('text', 'Loading input files...');
        % Load reference signal
        sInputA = bst_process('LoadInputFile', FilesA{iFile}, OPTIONS.TargetA, OPTIONS.TimeWindow, LoadOptionsA);
        if (size(sInputA.Data,2) < 2)
            bst_report('Error', OPTIONS.ProcessName, FilesA{iFile}, 'Invalid time selection, check the input time window.');
            return;
        end
        % Check for atlas-based files: no "after" option for the scouts
        if isfield(sInputA, 'Atlas') && ~isempty(sInputA.Atlas) && (length(sInputA.Atlas.Scouts) == size(sInputA.Data,1))
            OPTIONS.ScoutTime = 'before';
            sInputA.DataType  = 'matrix';
        end
        % Averaging: check for similar dimension in time
        if strcmpi(OPTIONS.OutputMode, 'avg')
            if (iFile == 1)
                nTimeA = size(sInputA.Data,2);
            elseif (size(sInputA.Data,2) ~= nTimeA)
                bst_report('Error', OPTIONS.ProcessName, FilesA{iFile}, 'Invalid time selection, probably due to different time vectors in the input files.');
                return;
            end
        end
        % Remove average
        if ~isempty(sAverageA)
            sInputA.Data = sInputA.Data - sAverageA.Data;
        end
        % If a target signal was defined
        if ~isConnNN
            % Load target signal
            sInputB = bst_process('LoadInputFile', FilesB{iFile}, OPTIONS.TargetB, OPTIONS.TimeWindow, LoadOptionsB);
            if isempty(sInputB.Data)
                bst_report('Error', OPTIONS.ProcessName, FilesB{iFile}, 'Invalid time selection, check the input time window.');
                return;
            end
            % Check for atlas-based files: no "after" option for the scouts
            if isfield(sInputB, 'Atlas') && ~isempty(sInputB.Atlas) && (length(sInputB.Atlas.Scouts) == size(sInputB.Data,1))
                OPTIONS.ScoutTime = 'before';
                sInputB.DataType  = 'matrix';
            end
            % Some quality check
            if (size(sInputA.Data,2) ~= size(sInputB.Data,2))
                bst_report('Error', OPTIONS.ProcessName, {FilesA{iFile}, FilesB{iFile}}, 'Files A and B must have the same number of time samples.');
                return;
            end
            % Remove average
            if ~isempty(sAverageB)
                sInputB.Data = sInputB.Data - sAverageB.Data;
            end
        % Else: Use the same info as FileA
        else
            sInputB = sInputA;
        end
    end
    % Get the sampling frequency
    sfreq = 1 ./ (sInputA.Time(2) - sInputA.Time(1));
    % Round the sampling frequency at 1e6
    sfreq = round(sfreq * 1e6) * 1e-6;
    
    % ===== CHECK UNCONSTRAINED SOURCES =====
    % Unconstrained models?
    isUnconstrA = ismember(sInputA.DataType, {'results', 'scouts', 'matrix'}) && ~isempty(sInputA.nComponents) && (sInputA.nComponents ~= 1);
    isUnconstrB = ismember(sInputB.DataType, {'results', 'scouts', 'matrix'}) && ~isempty(sInputB.nComponents) && (sInputB.nComponents ~= 1);
%     % Mixed source models not supported yet
%     if (ismember(sInputA.DataType, {'results', 'scouts', 'matrix'}) && ~isempty(sInputA.nComponents) && ~ismember(sInputA.nComponents, [1 3])) ...
%     || (ismember(sInputB.DataType, {'results', 'scouts', 'matrix'}) && ~isempty(sInputB.nComponents) && ~ismember(sInputB.nComponents, [1 3]))
%         bst_report('Error', OPTIONS.ProcessName, [], 'Connectivity functions are not supported yet for mixed source models.');
%         return;
%     end
    % PLV: Incompatible with unconstrained sources  (saves complex values)
    if ismember(OPTIONS.Method, {'plv','plvt','ciplv','ciplvt','wpli','wplit'}) && (isUnconstrA || isUnconstrB)
        bst_report('Error', OPTIONS.ProcessName, [], 'The PLV measures are not supported yet on unconstrained sources.');
        return;
    end
    
    % ===== GET SCOUTS SCTRUCTURES =====
    % Save scouts structures in the options
    % Scouts for FilesA
    if OPTIONS.isScoutA
        OPTIONS.sScoutsA = process_extract_scout('GetScoutsInfo', OPTIONS.ProcessName, [], sInputA.SurfaceFile, OPTIONS.TargetA);
    else
        OPTIONS.sScoutsA = [];
    end
    % Scouts for FilesB
    OPTIONS.sScoutsB = [];
    OPTIONS.sScoutsAtlasB = [];
    OPTIONS.sScoutsGridLocB = [];
    if OPTIONS.isScoutB
        [OPTIONS.sScoutsB, AtlasNames] = process_extract_scout('GetScoutsInfo', OPTIONS.ProcessName, [], sInputB.SurfaceFile, OPTIONS.TargetB);
        % Get atlas name
        uniqueAtlasNames = unique(AtlasNames);
        if (length(uniqueAtlasNames) == 1)
            OPTIONS.sScoutsAtlasNameB = AtlasNames{1};
            % Volume atlas: get the GridLoc
            if panel_scout('ParseVolumeAtlas', OPTIONS.sScoutsAtlasNameB)
                % Load the GridLoc from the first input source file
                warning off MATLAB:load:variableNotFound
                sResultsVol = load(file_fullpath(FilesB{iFile}), 'GridLoc');
                warning on MATLAB:load:variableNotFound
                % Return the GridLoc
                if ~isempty(sResultsVol) && isfield(sResultsVol, 'GridLoc')
                    OPTIONS.sScoutsGridLocB = sResultsVol.GridLoc;
                end
            end
        end
    end
    
    
    %% ===== COMPUTE CONNECTIVITY METRIC =====
    % The sections below must return R matrices with dimensions: [nA x nB x nTime x nFreq]
    switch (OPTIONS.Method)
        % === CORRELATION ===
        case 'corr'
            bst_progress('text', sprintf('Calculating: Correlation [%dx%d]...', size(sInputA.Data,1), size(sInputB.Data,1)));
            Comment = 'Corr: ';
            % All the correlations with one call
            R = bst_corrn(sInputA.Data, sInputB.Data, OPTIONS.RemoveMean); 
            
        % === COHERENCE ===
        case 'cohere'
            if (size(sInputA.Data,1) > 1) && (size(sInputB.Data,1) > 1)
                bst_progress('text', sprintf('Calculating: Coherence [%dx%d]...', size(sInputA.Data,1), size(sInputB.Data,1)));
            else
                bst_progress('text', 'Calculating: Coherence...');
            end
            % Compute in symmetrical way only for constrained sources
            CalculateSym = OPTIONS.isSymmetric && ~isUnconstrA && ~isUnconstrB;
            % Estimate the coherence (2021)
            if ~isempty(OPTIONS.WinLen)
                if ~iscell(sInputA.Data)
                    sInputA.Data = {sInputA.Data};
                end
                if ~isempty(sInputB.Data) && ~iscell(sInputB.Data)
                    sInputB.Data = {sInputB.Data};
                end
                [R, OPTIONS.Freqs, OPTIONS.Nwin, OPTIONS.Lwin, Messages] = bst_cohn_2021(sInputA.Data, sInputB.Data, sfreq, OPTIONS.WinLen, OPTIONS.CohOverlap, OPTIONS.CohMeasure, OPTIONS.MaxFreq, sInputB.ImagingKernel, round(100/length(FilesA)));
            % Estimate the coherence (deprecated)
            elseif ~isempty(OPTIONS.MaxFreqRes)
                [R, pValues, OPTIONS.Freqs, OPTIONS.Nwin, OPTIONS.Lwin, Messages] = bst_cohn(sInputA.Data, sInputB.Data, sfreq, OPTIONS.MaxFreqRes, OPTIONS.CohOverlap, OPTIONS.CohMeasure, CalculateSym, sInputB.ImagingKernel, round(100/length(FilesA)));
            end
            % Error processing
            if isempty(R)
                bst_report('Error', OPTIONS.ProcessName, unique({FilesA{iFile}, FilesB{iFile}}), Messages);
                return;
            elseif ~isempty(Messages)
                bst_report('Warning', OPTIONS.ProcessName, unique({FilesA{iFile}, FilesB{iFile}}), Messages);
            end
            % Remove the coherence at 0Hz => Meaningless
            iZero = find(OPTIONS.Freqs == 0);
            if ~isempty(iZero)
                OPTIONS.Freqs(iZero) = [];
                R(:,:,iZero) = [];
            end
            % Keep only the frequency bins we are interested in. For deprecated coherence
            if ~isempty(OPTIONS.MaxFreq) && (OPTIONS.MaxFreq ~= 0) && ~isempty(OPTIONS.MaxFreqRes)
                % Get frequencies of interest
                iFreq = find(OPTIONS.Freqs <= OPTIONS.MaxFreq);
                if isempty(iFreq)
                    bst_report('Error', OPTIONS.ProcessName, unique({FilesA{iFile}, FilesB{iFile}}), sprintf('No frequencies estimated below the highest frequency of interest (%1.2fHz). Nothing to save...', OPTIONS.MaxFreq));
                    return;
                end
                % Cut the unwanted frequencies
                R = R(:,:,iFreq);
                OPTIONS.Freqs = OPTIONS.Freqs(iFreq);
            end
            % Add the number of windows to the report
            bst_report('Info', OPTIONS.ProcessName, unique({FilesA{iFile}, FilesB{iFile}}), sprintf('Using %d windows of %d samples each', OPTIONS.Nwin, OPTIONS.Lwin));
            % Check precision for high frequencies
            fStep = OPTIONS.Freqs(2)-OPTIONS.Freqs(1);
            if (fStep < 0.1)
                precision = '%1.2f';
            else
                precision = '%1.1f';
            end
            % Output comment
            Comment = sprintf(['%s(' precision 'Hz,%dwin): '], OPTIONS.CohMeasure, fStep, OPTIONS.Nwin);
            % Reshape as [nA x nB x nTime x nFreq]
            R = reshape(R, size(R,1), size(R,2), 1, size(R,3));

        % ==== GRANGER ====
        case 'granger'
            bst_progress('text', sprintf('Calculating: Granger [%dx%d]...', size(sInputA.Data,1), size(sInputB.Data,1)));
            % Using the connectivity toolbox developed at USC
            inputs.partial     = 0;
            inputs.nTrials     = nTrials;
            inputs.standardize = true;
            inputs.flagFPE     = true;
            inputs.lag         = 0;
            inputs.flagELM     = false;
            %inputs.rho         = 50;
            % If computing a 1xN interaction: selection of the Granger orientation
            if (size(sInputA.Data,1) == 1) && strcmpi(OPTIONS.GrangerDir, 'in')
                R = bst_granger(sInputA.Data, sInputB.Data, OPTIONS.GrangerOrder, inputs);
            else
                % [sink x source] = bst_granger(sink, source, ...)
                R = bst_granger(sInputB.Data, sInputA.Data, OPTIONS.GrangerOrder, inputs);
            end
            % Granger function returns a connectivity matrix [sink x source] = [to x from] => Needs to be transposed
            R = R';
            % Comment
            if (size(sInputA.Data,1) == 1)
                Comment = ['Granger(' OPTIONS.GrangerDir '): '];
            else
                Comment = 'Granger: ';
            end
            
        % ==== GRANGER SPECTRAL ====
        case 'spgranger'
            bst_progress('text', sprintf('Calculating: Granger spectral [%dx%d]...', size(sInputA.Data,1), size(sInputB.Data,1)));
            % Using the connectivity toolbox developed at USC
            inputs.partial     = 0;
            inputs.nTrials     = nTrials;
            inputs.standardize = true;
            inputs.flagFPE     = true;
            inputs.lag         = 0;
            inputs.flagELM     = false;
            inputs.freqResolution = OPTIONS.MaxFreqRes;
            %inputs.rho         = 50;
            % If computing a 1xN interaction: selection of the Granger orientation
            if (size(sInputA.Data,1) == 1) && strcmpi(OPTIONS.GrangerDir, 'in')
                [R, pValues, OPTIONS.Freqs] = bst_granger_spectral(sInputA.Data, sInputB.Data, sfreq, OPTIONS.GrangerOrder, inputs);
            else
                [R, pValues, OPTIONS.Freqs] = bst_granger_spectral(sInputB.Data, sInputA.Data, sfreq, OPTIONS.GrangerOrder, inputs);
            end
            R = permute(R, [2 1 3]);
            % Remove the values at 0Hz => Meaningless
            iZero = find(OPTIONS.Freqs == 0);
            if ~isempty(iZero)
                OPTIONS.Freqs(iZero) = [];
                R(:,:,iZero) = [];
            end
            % Keep only the frequency bins we are interested in
            if ~isempty(OPTIONS.MaxFreq) && (OPTIONS.MaxFreq ~= 0)
                % Get frequencies of interest
                iFreq = find(OPTIONS.Freqs <= OPTIONS.MaxFreq);
                if isempty(iFreq)
                    bst_report('Error', OPTIONS.ProcessName, unique({FilesA{iFile}, FilesB{iFile}}), sprintf('No frequencies estimated below the highest frequency of interest (%1.2fHz). Nothing to save...', OPTIONS.MaxFreq));
                    return;
                end
                % Cut the unwanted frequencies
                R = R(:,:,iFreq);
                OPTIONS.Freqs = OPTIONS.Freqs(iFreq);
            end
            % Comment
            if (size(sInputA.Data,1) == 1)
                Comment = sprintf('SpGranger(%s,%1.1fHz): ', OPTIONS.GrangerDir, OPTIONS.Freqs(2)-OPTIONS.Freqs(1));
            else
                Comment = sprintf('SpGranger(%1.1fHz): ', OPTIONS.Freqs(2)-OPTIONS.Freqs(1));
            end
            % Reshape as [nA x nB x nTime x nFreq]
            R = reshape(R, size(R,1), size(R,2), 1, size(R,3));
            
        % ==== AEC ====
        % WARNING: This function has been deprecated. Now using the HENV implementation instead
        % See discussion on the forum: https://neuroimage.usc.edu/forums/t/30358
        case 'aec'   % DEPRECATED
            bst_progress('text', sprintf('Calculating: AEC [%dx%d]...', size(sInputA.Data,1), size(sInputB.Data,1)));
            Comment = 'AEC: ';
            % Get frequency bands
            nFreqBands = size(OPTIONS.Freqs, 1);
            BandBounds = process_tf_bands('GetBounds', OPTIONS.Freqs);

            % Initialize returned matrix
            R = zeros(size(sInputA.Data,1), size(sInputB.Data,1), nFreqBands);
            % Loop on each frequency band
            for iBand = 1:nFreqBands
                % Band-pass filter in one frequency band + Apply Hilbert transform
                DataAband = process_bandpass('Compute', sInputA.Data, sfreq, BandBounds(iBand,1), BandBounds(iBand,2));
                HA = hilbert_fcn(DataAband')';                
                if isConnNN
                    HB = HA;
                else
                    DataBband = process_bandpass('Compute', sInputB.Data, sfreq, BandBounds(iBand,1), BandBounds(iBand,2));
                    HB = hilbert_fcn(DataBband')';
                end
                if OPTIONS.isOrth
                    if isConnNN
                        for iSeed = 1:size(HA,1)
                            % Orthogonalize complex coefficients, based on Hipp et al. 2012
                            % HBo is the amplitude of the component orthogonal to HA                            
                            HBo = imag(bsxfun(@times, HB, conj(HA(iSeed,:))./abs(HA(iSeed,:))));
                            % The orthogonalized signal can be computed like this (not necessary here):
                            % HBos = real(HBo .* ((1i*HA)./abs(HA)));
                            % avoid rounding errors
                            HBo(abs(HBo./abs(HB))<2*eps)=0;
                            % Compute correlation coefficients
                            R(iSeed,:,iBand) = correlate_dims(abs(HBo), abs(HA(iSeed,:)), 2);
                        end
                        % average the two "directions"
                        R(:,:,iBand) = (R(:,:,iBand)+R(:,:,iBand)')/2;
                    else
                        for iSeed = 1:size(HA,1)
                            HAo = imag(bsxfun(@times, HA(iSeed,:), conj(HB)./abs(HB)));
                            HBo = imag(bsxfun(@times, HB, conj(HA(iSeed,:))./abs(HA(iSeed,:))));
                            % avoid rounding errors
                            HAo(abs(bsxfun(@rdivide,HAo,abs(HA(iSeed,:))))<2*eps)=0;
                            HBo(abs(HBo./abs(HB))<2*eps)=0;
                            % Compute correlation coefficients
                            r1 = correlate_dims(abs(HA(iSeed,:)), abs(HBo), 2);
                            r2 = correlate_dims(abs(HB), abs(HAo), 2);
                            R(iSeed,:,iBand) = (r1+r2)/2;
                        end
                    end
                else
                    ampA = abs(HA);
                    ampB = abs(HB);
                    R(:,:,iBand) = bst_corrn(ampA,ampB);
                end
            end
            % We don't want to compute again the frequency bands
            FreqBands = [];
            % Reshape as [nA x nB x nTime x nFreq]
            R = reshape(R, size(R,1), size(R,2), 1, size(R,3));
            
        % ==== PLV ====
        case {'plv', 'wpli', 'ciplv'}
            bst_progress('text', sprintf('Calculating: %s [%dx%d]...', upper(OPTIONS.Method), size(sInputA.Data,1), size(sInputB.Data,1)));
            % Get frequency bands
            nFreqBands = size(OPTIONS.Freqs, 1);
            BandBounds = process_tf_bands('GetBounds', OPTIONS.Freqs);
            nA = size(sInputA.Data,1);
            nB = size(sInputB.Data,1);
            % Initialization for ciPLV and wPLI
            if ismember(OPTIONS.Method, {'wpli'})
                % Replicate nB x HA, and nA x HB
                iA = repmat(1:nA, 1, nB)';
                iB = reshape(repmat(1:nB, nA, 1), [], 1);
            end

            % ===== IMPLEMENTATION G.DUMAS =====
            % Intitialize returned matrix
            R = zeros(nA, nB, nFreqBands);
            % Loop on each frequency band
            for iBand = 1:nFreqBands
                % Band-pass filter in one frequency band + Apply Hilbert transform
                if isConnNN
                    DataAband = process_bandpass('Compute', sInputA.Data, sfreq, BandBounds(iBand,1), BandBounds(iBand,2), 'bst-hfilter-2019', OPTIONS.isMirror);
                    HA = hilbert_fcn(DataAband')';
                    HB = HA;
                else
                    DataAband = process_bandpass('Compute', sInputA.Data, sfreq, BandBounds(iBand,1), BandBounds(iBand,2), 'bst-hfilter-2019', OPTIONS.isMirror);
                    DataBband = process_bandpass('Compute', sInputB.Data, sfreq, BandBounds(iBand,1), BandBounds(iBand,2), 'bst-hfilter-2019', OPTIONS.isMirror);
                    HA = hilbert_fcn(DataAband')';
                    HB = hilbert_fcn(DataBband')';
                end
                phaseA = HA ./ abs(HA);
                phaseB = HB ./ abs(HB);
                % Compute PLV (Divided by number of time samples)
                switch (OPTIONS.Method)
                    case 'plv'
                        R(:,:,iBand) = (phaseA*phaseB') / size(HA,2);
                        Comment = 'PLV: ';
                    case 'ciplv'
                        % Implementation proposed by Daniele Marinazzo, based on:
                        %    Bruna R, Maestu F, Pereda E
                        %    Phase locking value revisited: teaching new tricks to an old dog
                        %    Journal of Neural Engineering, Jun 2018
                        %    https://pubmed.ncbi.nlm.nih.gov/29952757
                        csd = phaseA * phaseB';
                        R(:,:,iBand) = (imag(csd)/size(HA,2)) ./ sqrt(1 + eps - (real(csd)/size(HA,2)) .* conj(real(csd)/size(HA,2)));
                        % R(:,:,iBand) = (imag((phaseA*phaseB'))/size(HA,2))./sqrt(1+eps-(real((phaseA*phaseB'))/size(HA,2)).^2);    % SLOWER
                        Comment = 'ciPLV: ';
                    case 'wpli'
                        % Implementation proposed by Daniele Marinazzo, based on:
                        %    Vinck M, Oostenveld R, van Wingerden M, Battaglia F, Pennartz CM
                        %    An improved index of phase-synchronization for electrophysiological data in the presence of volume-conduction, noise and sample-size bias
                        %    Neuroimage, Apr 2011
                        %    https://pubmed.ncbi.nlm.nih.gov/21276857
                        R(:,:,iBand) = reshape(mean(sin(angle(HA(iA,:)')-angle(HB(iB,:)')))' ./ mean(abs(sin(angle(HA(iA,:)')-angle(HB(iB,:)'))))',[],nB);  % Proposed by Daniele Marinazzo
                        Comment = 'wPLI: ';
                end
            end
            % We don't want to compute again the frequency bands
            FreqBands = [];
            % Reshape as [nA x nB x nTime x nFreq]
            R = reshape(R, nA, nB, 1, nFreqBands);
            
        % ==== PLV-TIME ====
        case {'plvt', 'wplit', 'ciplvt'}
            bst_progress('text', sprintf('Calculating: Time-resolved %s [%dx%d]...', upper(OPTIONS.Method), size(sInputA.Data,1), size(sInputB.Data,1)));
            % Get frequency bands
            nFreqBands = size(OPTIONS.Freqs, 1);
            BandBounds = process_tf_bands('GetBounds', OPTIONS.Freqs);
            % Time: vector of file B
            nTime = length(sInputB.Time);
            % Intitialize returned matrix
            nA = size(sInputA.Data,1);
            nB = size(sInputB.Data,1);
            R = zeros(nA * nB, nTime, nFreqBands);
            % Replicate nB x HA, and nA x HB
            iA = repmat(1:nA, 1, nB)';
            iB = reshape(repmat(1:nB, nA, 1), [], 1);

            % ===== VERSION S.BAILLET =====
            % PLV = exp(1i * (angle(HA) - angle(HB)));
            % Loop on each frequency band
            for iBand = 1:nFreqBands
                % Band-pass filter in one frequency band + Apply Hilbert transform
                if isConnNN
                    DataAband = process_bandpass('Compute', sInputA.Data, sfreq, BandBounds(iBand,1), BandBounds(iBand,2), 'bst-hfilter-2019', OPTIONS.isMirror);
                    HA = hilbert_fcn(DataAband')';
                    HB = HA;
                else
                    DataAband = process_bandpass('Compute', sInputA.Data, sfreq, BandBounds(iBand,1), BandBounds(iBand,2), 'bst-hfilter-2019', OPTIONS.isMirror);
                    DataBband = process_bandpass('Compute', sInputB.Data, sfreq, BandBounds(iBand,1), BandBounds(iBand,2), 'bst-hfilter-2019', OPTIONS.isMirror);
                    HA = hilbert_fcn(DataAband')';
                    HB = hilbert_fcn(DataBband')';
                end
                % Compute the PLV in time for each pair
                phaseA = HA(iA,:) ./ abs(HA(iA,:));
                phaseB = HB(iB,:) ./ abs(HB(iB,:));
                switch (OPTIONS.Method)
                    case 'plvt'
                        % R(:,:,iBand) = exp(1i * angle(HA(iA,:)./HB(iB,:)));  % Sylvain Baillet, slower
                        R(:,:,iBand) = (phaseA .* conj(phaseB));  % Daniele Marinazzo
                        Comment = 'PLVt: ';
                    case 'ciplvt'
                        % R(:,:,iBand) = (imag(exp(1i * angle(HA(iA,:)./HB(iB,:)))))./sqrt(1-(real(exp(1i * angle(HA(iA,:)./HB(iB,:))))/nTime).^2);     % SLOWER
                        csd = phaseA .* conj(phaseB);
                        R(:,:,iBand) = imag(csd) ./ (real(csd)/nTime) .* conj(real(csd)/nTime);
                        Comment = 'ciPLVt: ';
                    case 'wplit'
                        % R(:,:,iBand) = abs(sin(angle(HA(iA,:)')-angle(HB(iB,:)')))'./(sin(angle(HA(iA,:)')-angle(HB(iB,:)')))';    % SLOWER
                        cdi = imag(phaseA .* conj(phaseB));
                        R(:,:,iBand) = abs(cdi) .* sign(cdi) ./ abs(cdi);
                        Comment = 'wPLIt: ';
                end
            end
            % We don't want to compute again the frequency bands
            FreqBands = [];
            % Reshape as [nA x nB x nTime x nFreq]
            R = reshape(R, nA, nB, nTime, nFreqBands);

        % ==== PTE ====
        case 'pte'
            bst_progress('text', sprintf('Calculating: PTE [%dx%d]...', size(sInputA.Data,1), size(sInputB.Data,1)));
            Comment = 'PTE';
            if OPTIONS.isNormalized
                Comment = [Comment, ' [Normalized]'];
            end
            Comment = [Comment, ': '];
            % Get frequency bands
            nFreqBands = size(OPTIONS.Freqs, 1);
            BandBounds = process_tf_bands('GetBounds', OPTIONS.Freqs);
            % Intitialize returned matrix
            R = zeros(size(sInputA.Data,1), size(sInputB.Data,1), 1, nFreqBands);
            % Loop on each frequency band
            for iBand = 1:nFreqBands
                % Band-pass filter in one frequency band + Apply Hilbert transform
                DataAband = process_bandpass('Compute', sInputA.Data, sfreq, BandBounds(iBand,1), BandBounds(iBand,2), 'bst-hfilter-2019', OPTIONS.isMirror);
                % Compute PTE
                [dPTE, PTE] = PhaseTE_MF(permute(DataAband, [2 1]));
                if OPTIONS.isNormalized
                    R(:,:,1,iBand) = dPTE;
                else
                    R(:,:,1,iBand) = PTE;
                end
            end
            % We don't want to compute again the frequency bands
            FreqBands = [];
            
        % ==== henv ====
        case 'henv'
            bst_progress('text', sprintf('Calculating: %s [%dx%d]...',OPTIONS.CohMeasure, size(sInputA.Data,1), size(sInputB.Data,1)));
            % Process options
            OPTIONS.SampleRate = sfreq;
            OPTIONS.Freqs      = OPTIONS.Freqrange;
            % Compute envelope correlation
            [R, timeSamples, Nwin] = bst_henv(sInputA.Data, sInputB.Data, sInputA.Time, OPTIONS);
            % Output file time
            sInputB.Time = timeSamples + sInputB.Time(1);
            % File comment
            Comment = sprintf('%s (%s, %1.2fs, %dwin): ', OPTIONS.CohMeasure, OPTIONS.tfMeasure, OPTIONS.WinLength, Nwin);
                    
        otherwise
            bst_report('Error', OPTIONS.ProcessName, [], ['Invalid method "' OPTIONS.Method '".']);
            return;
    end
    % Replace any NaN values with zeros
    R(isnan(R)) = 0;
    R(isinf(R)) = 0;
    
    
    %% ===== PROCESS UNCONSTRAINED SOURCES: MAX =====
    % R matrix is: [nA x nB x nTime x nFreq]
    if isUnconstrA || isUnconstrB
        % If there are negative values: take the signed absolute maximum
        if any(R(:) < 0)
            UnconstrFunc = 'absmax';
        % If all the values are positive: use Matlab's max()
        else
            UnconstrFunc = 'max';
        end
        % Dimension #1
        if isUnconstrA
            [R, sInputA.GridAtlas, sInputA.RowNames] = bst_source_orient([], sInputA.nComponents, sInputA.GridAtlas, R, UnconstrFunc, sInputA.DataType, sInputA.RowNames);
        end
        % Dimension #2
        if isUnconstrB
            R = permute(R, [2 1 3 4]);
            [R, sInputB.GridAtlas, sInputB.RowNames] = bst_source_orient([], sInputB.nComponents, sInputB.GridAtlas, R, UnconstrFunc, sInputB.DataType, sInputB.RowNames);
            R = permute(R, [2 1 3 4]);
        end
    end

    %% ===== SAVE FILE =====
    % Reshape: [nA x nB x nTime x nFreq] => [nA*nB x nTime x nFreq]
    R = reshape(R, [], size(R,3), size(R,4));
    % Comment
    % 1xN and AxB
    if ~isConnNN
        % Seed (scout)
        if OPTIONS.isScoutA
            if (length(OPTIONS.sScoutsA) == 1)
                Comment = [Comment, OPTIONS.sScoutsA.Label];
            end
        % Seed (sensor or row)
        elseif (length(sInputA.RowNames) == 1)
            if iscell(sInputA.RowNames)
                Comment = [Comment, sInputA.RowNames{1}];
            else
                Comment = [Comment, '#', num2str(sInputA.RowNames(1))];
            end
        end
        % Number of target (scouts)
        if OPTIONS.isScoutB
            Comment = [Comment, ' x ' num2str(length(OPTIONS.sScoutsB)), ' scouts'];
        end
        % Add scout function and time if they are relevant
        if ~strcmpi(OPTIONS.ScoutFunc, 'All') && (OPTIONS.isScoutA || OPTIONS.isScoutB)
             Comment = [Comment, ', ',  OPTIONS.ScoutFunc, ' ', OPTIONS.ScoutTime];
        end
    %NxN
    else
        Comment = [Comment, sInputA.Comment];
    end
    % Save each connectivity matrix as an independent file
    switch (OPTIONS.OutputMode)
        case 'input'
            nAvg = 1;
            OutputFiles{end+1} = SaveFile(R, sInputB.iStudy, FilesB{iFile}, sInputA, sInputB, Comment, nAvg, OPTIONS, FreqBands);
        case {'concat', 'avgcoh'}
            nAvg = 1;
            OutputFiles{end+1} = SaveFile(R, OPTIONS.iOutputStudy, [], sInputA, sInputB, Comment, nAvg, OPTIONS, FreqBands);
        case 'avg'
            % Concatenate files comments
            AllComments{end+1} = Comment;
            % Compute online average of the connectivity matrices
            if isempty(Ravg)
                Ravg = R ./ length(FilesA);
            elseif ~isequal(size(Ravg), size(R))
                bst_report('Error', OPTIONS.ProcessName, [], 'Input files have different size dimensions or different lists of bad channels.');
                return;
            else
                Ravg = Ravg + R ./ length(FilesA);
            end
            nAvg = nAvg + 1;
    end
end

%% ===== SAVE AVERAGE =====
if strcmpi(OPTIONS.OutputMode, 'avg')
    OutputFiles{1} = SaveFile(Ravg, OPTIONS.iOutputStudy, [], sInputA, sInputB, AllComments, nAvg, OPTIONS, FreqBands);
end


end



%% ========================================================================
%  ===== SUPPORT FUNCTIONS ================================================
%  ========================================================================

%% ===== SAVE FILE =====
function NewFile = SaveFile(R, iOutputStudy, DataFile, sInputA, sInputB, Comment, nAvg, OPTIONS, FreqBands)
    NewFile = [];
    bst_progress('text', 'Saving results...');

    % ===== PREPARE OUTPUT STRUCTURE =====
    % Create file structure
    FileMat = db_template('timefreqmat');
    FileMat.TF        = R;
    FileMat.Comment   = Comment;
    FileMat.DataType  = sInputB.DataType;
    FileMat.Freqs     = OPTIONS.Freqs;
    FileMat.Method    = OPTIONS.Method;
    FileMat.DataFile  = file_win2unix(DataFile);
    FileMat.nAvg      = nAvg;
    % Comment if average comes from trials
    if FileMat.nAvg > 1
        listComments = Comment;
        % If Comments are the same
        if length(unique(listComments)) > 1
            % Search for trial tags and remove them
            for iComment = 1 : length(listComments)
                [~, tmpStrs] = regexp(listComments{iComment},'\(#.+\)','match','split');
                listComments{iComment} = deblank([tmpStrs{:}]);
            end
        end
        if (length(unique(listComments)) == 1)
            Comment = listComments{1};
        else
            Comment = listComments{end};
        end
        FileMat.Comment = sprintf('Avg: %s (%d)', Comment, FileMat.nAvg);
    end
    % Head model
    if isfield(sInputA, 'HeadModelFile') && ~isempty(sInputA.HeadModelFile)
        FileMat.HeadModelFile = sInputA.HeadModelFile;
        FileMat.HeadModelType = sInputA.HeadModelType;
    elseif isfield(sInputB, 'HeadModelFile') && ~isempty(sInputB.HeadModelFile)
        FileMat.HeadModelFile = sInputB.HeadModelFile;
        FileMat.HeadModelType = sInputB.HeadModelType;
    end
    % Time vector
    if ismember(OPTIONS.Method, {'plvt','ciplvt','wplit','henv'})
        FileMat.Time      = sInputB.Time;
        FileMat.TimeBands = [];
    else
        FileMat.Time      = sInputB.Time([1,end]);
        FileMat.TimeBands = {OPTIONS.Method, sInputB.Time(1), sInputB.Time(end)};
    end
    % Measure
    if ismember(OPTIONS.Method, {'plv','plvt','ciplv','ciplvt','wpli','wplit'})
        % Apply measure
        switch (OPTIONS.PlvMeasure)
            case 'magnitude'
                FileMat.TF = abs(FileMat.TF);
                FileMat.Measure = 'other';
            otherwise
                FileMat.Measure = 'none';
        end
    else
        FileMat.Measure = 'other';
    end
    % Row names: NxM
    FileMat.RefRowNames = sInputA.RowNames;
    FileMat.RowNames    = sInputB.RowNames;
    % Atlas 
    if OPTIONS.isScoutB
        % Save the atlas in the file
        FileMat.Atlas = db_template('atlas');
        if ~isempty(OPTIONS.sScoutsAtlasNameB)
            FileMat.Atlas.Name = OPTIONS.sScoutsAtlasNameB;
        else
            FileMat.Atlas.Name = OPTIONS.ProcessName;
        end
        if ~isempty(OPTIONS.sScoutsGridLocB)
            FileMat.GridLoc = OPTIONS.sScoutsGridLocB;
        end
        FileMat.Atlas.Scouts = OPTIONS.sScoutsB;
    elseif ~isempty(sInputB.Atlas)
        FileMat.Atlas = sInputB.Atlas;
    end
    if ~isempty(sInputB.SurfaceFile)
        FileMat.SurfaceFile = sInputB.SurfaceFile;
    end
    if ~isempty(sInputB.GridLoc)
        FileMat.GridLoc = sInputB.GridLoc;
    end
    if ~isempty(sInputB.GridAtlas)
        FileMat.GridAtlas = sInputB.GridAtlas;
    end
    % History: Computation
    FileMat = bst_history('add', FileMat, 'compute', ['Connectivity measure: ', OPTIONS.Method, ' (see the field "Options" for input parameters)']);
    % Save options structure
    FileMat.Options = OPTIONS;
    % Apply time and frequency bands
    if ~isempty(FreqBands)
        FileMat = process_tf_bands('Compute', FileMat, FreqBands, []);
        if isempty(FileMat)
            bst_report('Error', OPTIONS.ProcessName, [], 'Error computing the frequency bands.');
            return;
        end
    end

    % ===== PROCESS SCOUTS =====
    % Process scouts: call aggregating function
    if (OPTIONS.isScoutA || OPTIONS.isScoutB) && strcmpi(OPTIONS.ScoutTime, 'after') && ~strcmpi(OPTIONS.ScoutFunc, 'all')
        FileMat = process_average_rows('ProcessConnectScouts', FileMat, OPTIONS.ScoutFunc, OPTIONS.sScoutsA, OPTIONS.sScoutsB);
    end
    
    % ===== OPTIMIZE STORAGE FOR SYMMETRIC MATRIX =====
    % Keep only the values below the diagonal
    if FileMat.Options.isSymmetric && (size(FileMat.TF,1) == length(FileMat.RowNames)^2)
        FileMat.TF = process_compress_sym('Compress', FileMat.TF);
    end
        
    % ===== SAVE FILE =====
    if OPTIONS.isSave
        % Get output study
        sOutputStudy = bst_get('Study', iOutputStudy);
        % File tag
        if (length(FileMat.RefRowNames) == 1)
            fileTag = 'connect1';
        else
            fileTag = 'connectn';
        end
        % Output filename
        NewFile = bst_process('GetNewFilename', bst_fileparts(sOutputStudy.FileName), ['timefreq_' fileTag '_' OPTIONS.Method]);
        % Save file
        bst_save(NewFile, FileMat, 'v6');
        % Add file to database structure
        db_add_data(iOutputStudy, NewFile, FileMat);
    else
        NewFile = FileMat;
    end
end


%% ===== LOAD ALL INPUTS =====
function [sConcat, sAverage] = LoadAll(FileNames, Target, TimeWindow, LoadOptions, isConcat, isAverage, startValue)
    sConcat = [];
    sAverage = [];
    for iFile = 1:length(FileNames)
        % Load file
        bst_progress('set',  round(startValue + (iFile-1) / length(FileNames) * 100));
        sTmp = bst_process('LoadInputFile', FileNames{iFile}, Target, TimeWindow, LoadOptions);
        if isempty(sTmp.Data)
            return;
        end
        % Concatenate with previous file (old coherence)
        if (isConcat == 1)
            if isempty(sConcat)
                sConcat = sTmp;
            elseif ~isequal(size(sConcat.Data,1), size(sTmp.Data,1))
                sAverage = [];
                sConcat = [];
                return;
            else
                sConcat.Data = [sConcat.Data, sTmp.Data];
                sConcat.Time = [sConcat.Time, sTmp.Time + sTmp.Time(2) - 2*sTmp.Time(1) + sConcat.Time(end)];
            end
        % Load a cell array (coherence 2021)
        elseif (isConcat == 2)
            if isempty(sConcat)
                sConcat = sTmp;
                sConcat.Data = {sConcat.Data};
            else
                sConcat.Data{end+1} = sTmp.Data;
                sConcat.Time = [sConcat.Time, sTmp.Time + sTmp.Time(2) - 2*sTmp.Time(1) + sConcat.Time(end)];
            end
        end
        % Average with previous files
        if isAverage
            if isempty(sAverage)
                sAverage = sTmp;
                sAverage.Data = sAverage.Data ./ length(FileNames);
            else
                if ~isequal(size(sAverage.Data), size(sTmp.Data))
                    sAverage = [];
                    sConcat = [];
                    return;
                end
                sAverage.Data = sAverage.Data + sTmp.Data ./ length(FileNames);
            end
        end
    end
    % Remove average from concatenated files
    if (isConcat >= 1) && isAverage
        for iFile = 1:length(FileNames)
            if (isConcat == 1)
                iSmp = [1, size(sAverage.Data,2)] + (iFile-1) * size(sAverage.Data,2);
                sConcat.Data(:,iSmp(1):iSmp(2)) = sConcat.Data(:,iSmp(1):iSmp(2)) - sAverage.Data;
            elseif (isConcat == 2)
                sConcat.Data{iFile} = sConcat.Data{iFile} - sAverage.Data;
            end
        end
    end
end


function R = correlate_dims(A, B, dim)
    A = bsxfun( @minus, A, mean( A, dim) );
    B = bsxfun( @minus, B, mean( B, dim) );
    A = normr(A);
    B = normr(B);
    R = sum(bsxfun(@times, A, B), dim);
end

function x = normr(x)
    n = sqrt(sum(x.^2,2));
    x(n~=0,:) = bst_bsxfun(@rdivide, x(n~=0,:), n(n~=0));
    x(n==0,:) = 1 ./ sqrt(size(x,2));
end
