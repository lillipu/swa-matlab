function [Data, Info, SS] = swa_FindSSRef(Data, Info)
% Automatic spindle detection on a reference channel using continuous 
% wavelet transform

% The algorithm used is built on the one used by Wamsley et al 2012 which 
% was the highest rated automatic detection algorithm in a comparison by
% Warby et al 2014 (NatureMethods). 
% Here this is improved upon by: using a 
% - shorter default minimum detection window (300ms instead of 500ms), a 
%   change which puts the method ahead of non-expert consensus in the study
%   by Warby et al
% - using a dynamic threshold based on the standard deviation above the
%   mean in the power spectrum (and not just the mean), which would
%   stabalise the results across different nights/participants
% - finding the true start of the spindle by calculating the lowest trough
%   in the power spectrum prior to passing the threshold (end as well)
% - performing an additional wavelet transform to determine whether the 
%   spindle is best classified as a slow or fast variant

%% Initialise the SS Structure
SS = struct(...
    'Ref_Region',               [],...
    'Ref_Start',                [],...
    'Ref_End',                  [],...
    'Ref_FreqPeak',             [],...
    'Ref_NegativePeak',         [],...
    'Ref_PositivePeak',         [],...
    'Ref_Peak2Peak',            [],...
    'Ref_Length',               [],...
    'Ref_NumberOfWaves',        [],...
    'Ref_Symmetry',             [],...
    'Channels_Active',          [],...
    'Channels_Peak2PeakAmp',    [],...
    'Channels_Globality',       [],...   
    'Travelling_Delays',        [],...
    'Travelling_DelayMap',      [],...
    'Travelling_Density',       [],...
    'Travelling_Streams',       []);

% intiialise spindle count
SS_count  = 0;

%% Info defaults
if ~isfield(Info, 'Parameters')
    % get general defaults
    Info = swa_getInfoDefaults(Info, 'SS');
    fprintf('Information: No parameters found in Info, using defaults\n');
end

% Wavelet Parameters
waveName = Info.Parameters.Wavelet_name;
wavelet_center = centfrq(waveName);
freqCent = Info.Parameters.Filter_band(1) : 0.5 : Info.Parameters.Filter_band(2);
scales = wavelet_center./(freqCent./ Info.Recording.sRate);

% Loop for each Reference Wave
for ref_wave = 1 : size(Data.SSRef, 1)
    
    % how many spindles have been detected?
    if isempty(SS)
        original_count = 0;
    else
        original_count = length(SS);
    end
    
    % --Continuous Wavelet Transform -- %
    cwtCoeffs = cwt(Data.SSRef(ref_wave, :), scales, waveName);
    cwtCoeffs = abs(cwtCoeffs.^ 2);
    cwtPower = nanmean(cwtCoeffs);
    
    % smooth the wavelet power
    window = ones(round(Info.Recording.sRate * Info.Parameters.Filter_Window), 1)...
        / round(Info.Recording.sRate * Info.Parameters.Filter_Window);
    Data.CWT(ref_wave, :) = filtfilt(window, 1, cwtPower);  
    
    % -- Threshold crossings -- %
    % Calculate power threshold criteria
    if strcmp(Info.Parameters.Ref_AmplitudeCriteria, 'relative')
        % calculate the standard deviation from the median
        std_wavelet = nanstd(Data.CWT(ref_wave, :), 1);
        % calculate the absolute threshold for that canonical wave
        Info.Parameters.Ref_AmplitudeAbsolute(ref_wave) = ...
            (std_wavelet * Info.Parameters.Ref_AmplitudeRelative)...
            + mean(Data.CWT(ref_wave, :));
    else
        % repeat 
        Info.Parameters.Ref_AmplitudeAbsolute = ...
            repmat(Info.Parameters.Ref_AmplitudeAbsolute, 1, size(Data.SSRef, 1));
    end
    
    % -- Get the times where power data is above threshold --%
    signData = sign(Data.CWT(ref_wave, :) - Info.Parameters.Ref_AmplitudeAbsolute(ref_wave));
    power_start = find(diff(signData) == 2);
    power_end = find(diff(signData) == -2);
    
    % Check for earlier start than end
    if power_end(1) < power_start(1)
        power_end(1) = [];
    end
    
    % Check for end after start
    if length(power_start) > length(power_end)
        power_start(end) = [];
    end
    
    % Check Soft Minimum Length (30% less than actual minimum) %
    SS_lengths = power_end - power_start;
    minimum_length = (Info.Parameters.Ref_WaveLength(1) / 1.3) * Info.Recording.sRate;
    
    % remove all potentials under the soft minimum length
    power_start(SS_lengths < minimum_length) = [];
    power_end(SS_lengths < minimum_length) = [];
    
    % -- find negative troughs in the power signal near the crossings -- %
    % calculate the differential
    slope_power = [0 diff(Data.CWT(ref_wave, :))];
    % local minima points
    power_MNP = [1, find(diff(sign(slope_power))== 2)];
       
    % Calculate the actual start of the spindle from powerData
    % TODO: make minimum threshold in case of smooth slope
    actual_start = nan(length(power_start), 1);
    actual_end = nan(length(power_start), 1);
    for n = 1 : length(power_start)
        actual_start(n) = power_MNP(sum(power_start(n) - power_MNP > 0));
        actual_end(n) = power_MNP(sum(power_end(n) - power_MNP > 0) + 1);
    end
    
    % Check Hard Minimum Length %
    SS_lengths = actual_end - actual_start;
    minimum_length = Info.Parameters.Ref_WaveLength(1) * Info.Recording.sRate;
    
    actual_start(SS_lengths < minimum_length) = [];
    actual_end(SS_lengths < minimum_length) = [];
    SS_lengths(SS_lengths < minimum_length) = [];
    
    % Check Maximum Length %
    maximum_length = Info.Parameters.Ref_WaveLength(2) * Info.Recording.sRate;
    actual_start(SS_lengths > maximum_length) = [];
    actual_end(SS_lengths > maximum_length) = [];
    SS_lengths(SS_lengths > maximum_length) = [];   
    
    % TODO: Check neighbouring frequencies to ensure its spindle specific

    
    % Calculate slope of reference data
    slope_canonical  = [0 diff(Data.SSRef(ref_wave, :))];
    
    % Find mid point of all waves calculated so far
    midpoint_SS = [SS.Ref_Start] + [SS.Ref_Length] / 2;

    % Loop through each spindle found
    for n = 1 : length(actual_start)
        
        % -- Find the local peaks and troughs -- %
        % Calculate the slope of the original wave
        slope_SS  = slope_canonical(:, actual_start(n) : actual_end(n));
        
        % Find all the peaks, both positive and negative
        peak_indices = find(abs(diff(sign(slope_SS))) == 2);
        peak_amplitudes = Data.SSRef(ref_wave,...
            actual_start(n) - 1 + peak_indices);
        
        % find the maximum peak to peak difference
        [peak2peak, max_indice] = max(abs(diff(peak_amplitudes)));
        
        % -- check for the number of individual waves -- %
        if length(peak_amplitudes) < Info.Parameters.Ref_MinWaves * 2
            continue;
        end
        
        % -- find peak frequency -- %
        % extract spindle segment with a data buffer
        spindle_segment = Data.SSRef(ref_wave, ...
            actual_start(n) - floor(Info.Recording.sRate) / 4 : ...
            actual_end(n) + floor(Info.Recording.sRate) / 4);
        
        % calculate the power spectrum using pwelch
        [spectrum_segment, freq_range] = pwelch(spindle_segment, ...
            length(spindle_segment), ...
            0, ...
            2 * Info.Recording.sRate,...
            Info.Recording.sRate);
        
        % find the peak in the spindle range
        [~, max_ind] = max(spectrum_segment(...
            freq_range >= Info.Parameters.Filter_band(1) & ...
            freq_range <= Info.Parameters.Filter_band(2)));
        peak_frequency = Info.Parameters.Filter_band(1) + (max_ind - 1) * 0.5; % because 2s windows in the pwelch
        
        
        % -- Save Wave to Structure -- %
        % Check if the SS has already been found in another reference channel
        if ref_wave > 1
            [c, SS_indice] = max(double(midpoint_SS > actual_start(n)) + double(midpoint_SS < actual_end(n)));
            if c == 2              
                % Check which region has the bigger P2P wave...
                if peak2peak > SS(SS_indice).Ref_Peak2Peak
                    % If the new region does then overwrite previous data with larger reference
                    SS(SS_indice).Ref_Region          =      [ref_wave, SS(SS_indice).Ref_Region];
                    SS(SS_indice).Ref_NegativePeak    =      min(peak_amplitudes);
                    SS(SS_indice).Ref_PositivePeak    =      max(peak_amplitudes);
                    SS(SS_indice).Ref_Peak2Peak       =      peak2peak;
                    SS(SS_indice).Ref_FreqPeak        =      peak_frequency;
                    SS(SS_indice).Ref_Start           =      actual_start(n);
                    SS(SS_indice).Ref_End             =      actual_end(n);                    
                    SS(SS_indice).Ref_Length          =      SS_lengths(n);
                    SS(SS_indice).Ref_NumberOfWaves   =      length(peak_amplitudes)/2;
                    SS(SS_indice).Ref_Symmetry        =      max_indice/(length(peak_amplitudes)-1);
                else
                    SS(SS_indice).Ref_Region(end+1)   = ref_wave;
                end
                
                continue;
            end
        end
        
        SS_count = SS_count + 1;

        SS(SS_count).Ref_Region          =      ref_wave;
        SS(SS_count).Ref_NegativePeak    =      min(peak_amplitudes);
        SS(SS_count).Ref_PositivePeak    =      max(peak_amplitudes);
        SS(SS_count).Ref_Peak2Peak       =      peak2peak;
        SS(SS_count).Ref_FreqPeak        =      peak_frequency;
        SS(SS_count).Ref_Start           =      actual_start(n);
        SS(SS_count).Ref_End             =      actual_end(n);
        SS(SS_count).Ref_Length          =      SS_lengths(n);
        SS(SS_count).Ref_NumberOfWaves   =      length(peak_amplitudes) / 2;
        SS(SS_count).Ref_Symmetry        =      max_indice/(length(peak_amplitudes) - 1);

    end
    
    % brief report of the spindles found
    if ref_wave == 1
        fprintf(1, 'Information: %d spindle bursts found in reference wave \n', length(SS));
    else
        fprintf(1, 'Information: %d spindle bursts added from region %d \n', length(SS) - original_count, ref_wave);
    end
    
end

% Sort SS structure by timing of main peak
midpoint_SS = [SS.Ref_Start];
[~, sort_indices] = sort(midpoint_SS);
SS = SS(sort_indices);