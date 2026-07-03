function make_survey_corpus(outDir)
%MAKE_SURVEY_CORPUS Files mimicking the CRCNS hard cases, for survey testing.

if isfolder(outDir), rmdir(outDir, 's'); end
mkdir(outDir);

% 1. CRCNS-style ephys: per-trial struct array with spike-time cells
nUnits = 20;
ephys.spikes = arrayfun(@(u) sort(rand(1, randi(500)) * 1000), 1:nUnits, ...
    'UniformOutput', false); %#ok<STRNU>
ephys.trials = struct('onset', num2cell((1:50) * 2.0), ...
    'label', repmat({'go', 'nogo'}, 1, 25)); %#ok<STRNU>
ephys.meta = struct('subject', 'M42', 'fs', 30000, 'region', 'CA1'); %#ok<STRNU>
save(fullfile(outDir, 'crcns_ephys.mat'), '-struct', 'ephys', '-v7.3');

% 2. big dense array (imaging-like)
img = single(reshape(1:2e6, [1000 2000]) / 1e6); %#ok<NASGU>
save(fullfile(outDir, 'imaging_big.mat'), 'img', '-v7.3');

% 3. complex + sparse (signal processing; hits clean-error paths)
spectrum = fft(randn(1, 4096)); %#ok<NASGU>
adjacency = sparse(randi(100, 1, 200), randi(100, 1, 200), 1, 100, 100); %#ok<NASGU>
save(fullfile(outDir, 'signals.mat'), 'spectrum', 'adjacency', '-v7.3');

% 4. deeply nested mixed cells
deep = {1, {2, {3, {'four', struct('five', 5)}}}, magic(4)}; %#ok<NASGU>
save(fullfile(outDir, 'nested.mat'), 'deep', '-v7.3');

% 5. legacy v7 (must be rejected cleanly)
legacy = magic(10); %#ok<NASGU>
save(fullfile(outDir, 'legacy_v7.mat'), 'legacy', '-v7');

fprintf('corpus written to %s\n', outDir);
end
