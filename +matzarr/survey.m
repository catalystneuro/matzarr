function report = survey(folder, opts)
%SURVEY Try to index every .mat file under a folder and report coverage.
%   report = matzarr.survey("~/crcns_downloads")
%
%   For each file: attempts matzarr.index, then reads every top-level
%   variable back and compares against MATLAB's own load (the oracle).
%   Classifies each file as:
%     ok        - indexed and every variable round-trips
%     mismatch  - indexed but a variable read back wrong  (SILENT BUG - worst)
%     unsupported - a named matzarr error (expected: v7 file, complex, ...)
%     error     - an unexpected failure
%
%   Options:
%     Verify   (true)  read back and compare (needs the file to fit in RAM)
%     MaxBytes (Inf)   skip files larger than this for the verify step
%     Pattern  ("*.mat")
%
%   Returns a table; also prints a summary and a variable-class histogram.

arguments
    folder (1,1) string
    opts.Verify (1,1) logical = true
    opts.MaxBytes (1,1) double = Inf
    opts.Pattern (1,1) string = "*.mat"
end

files = dir(fullfile(folder, "**", opts.Pattern));
files = files(~[files.isdir]);
if isempty(files)
    error("matzarr:survey:NoFiles", "No files matching %s under %s.", ...
        opts.Pattern, folder);
end

n = numel(files);
name = strings(n, 1);
sizeMB = zeros(n, 1);
status = strings(n, 1);
detail = strings(n, 1);
nVars = zeros(n, 1);
indexSec = zeros(n, 1);
classHist = containers.Map('KeyType', 'char', 'ValueType', 'double');

for i = 1:n
    fpath = string(fullfile(files(i).folder, files(i).name));
    name(i) = string(files(i).name);
    sizeMB(i) = files(i).bytes / 1e6;
    fprintf('[%d/%d] %s (%.0f MB) ... ', i, n, files(i).name, sizeMB(i));

    if ~isHDF5(fpath)
        status(i) = "unsupported";
        detail(i) = "not v7.3 (pre-HDF5 .mat); matzarr targets v7.3";
        fprintf('%s\n', detail(i));
        continue
    end

    indexDir = fullfile(tempname, "idx.zarr");
    cleanup = onCleanup(@() rmdirIf(fileparts(indexDir)));
    t = tic;
    try
        matzarr.index(fpath, indexDir);
    catch err
        indexSec(i) = toc(t);
        [status(i), detail(i)] = classifyError(err);
        fprintf('%s: %s\n', status(i), truncate(detail(i)));
        clear cleanup
        continue
    end
    indexSec(i) = toc(t);

    f = matzarr.open(indexDir);
    vars = f.who();
    nVars(i) = numel(vars);

    if ~opts.Verify || sizeMB(i) > opts.MaxBytes / 1e6
        status(i) = "indexed";
        detail(i) = sprintf("%d variables (verify skipped)", numel(vars));
        recordClasses(fpath, vars, classHist);
        fprintf('indexed, %d vars (not verified)\n', numel(vars));
        clear cleanup
        continue
    end

    truth = load(fpath);
    ok = true;
    badVar = "";
    for v = reshape(vars, 1, [])
        try
            got = f.getVariable(v);
            if isa(got, 'zarr.Array'), got = got.read(); end
        catch err
            [st, de] = classifyError(err);
            if st == "unsupported"
                continue  % a class matzarr declines; not a failure of the file
            end
            ok = false; badVar = v + " (" + err.message + ")"; break;
        end
        fld = matlab.lang.makeValidName(v);
        if isfield(truth, fld) && ~isequaln(got, truth.(fld))
            ok = false; badVar = v + " (values differ)"; break;
        end
    end
    recordClasses(fpath, vars, classHist);

    if ok
        status(i) = "ok";
        detail(i) = sprintf("%d variables verified", numel(vars));
        fprintf('OK (%d vars)\n', numel(vars));
    else
        status(i) = "mismatch";
        detail(i) = "SILENT MISMATCH: " + badVar;
        fprintf('*** MISMATCH: %s\n', truncate(badVar));
    end
    clear cleanup
end

report = table(name, sizeMB, status, nVars, indexSec, detail);
printSummary(report, classHist);
end

% ---------------------------------------------------------------------
function tf = isHDF5(fpath)
% .mat v7.3 files begin with a text header "MATLAB 7.3 MAT-file..." in a
% 512-byte userblock, then the HDF5 signature; v5/v7 say "MATLAB 5.0".
fid = fopen(fpath, 'r');
if fid == -1, tf = false; return; end
hdr = fread(fid, 16, '*char')';
fclose(fid);
tf = contains(string(hdr), "MATLAB 7.3");
end

function [status, detail] = classifyError(err)
if startsWith(string(err.identifier), "matzarr:") && ...
        contains(string(err.identifier), ["Unsupported", "SelfCheck"])
    status = "unsupported";
else
    status = "error";
end
detail = string(err.message);
end

function recordClasses(fpath, vars, hist)
try
    info = whos('-file', char(fpath));
catch
    return
end
for k = 1:numel(info)
    if ismember(string(info(k).name), vars)
        c = info(k).class;
        if hist.isKey(c), hist(c) = hist(c) + 1; else, hist(c) = 1; end
    end
end
end

function printSummary(report, classHist)
fprintf('\n===== survey summary (%d files) =====\n', height(report));
cats = ["ok", "indexed", "mismatch", "unsupported", "error"];
for c = cats
    m = report.status == c;
    if any(m)
        fprintf('  %-12s %3d\n', c, nnz(m));
    end
end
if any(report.status == "mismatch")
    fprintf('  >>> %d file(s) read back WRONG — investigate first.\n', ...
        nnz(report.status == "mismatch"));
end
if classHist.Count > 0
    fprintf('  variable classes seen: ');
    ks = string(classHist.keys());
    parts = arrayfun(@(k) k + "=" + string(classHist(char(k))), ks);
    fprintf('%s\n', strjoin(parts, ", "));
end
end

function s = truncate(s)
s = string(s);
if strlength(s) > 70, s = extractBefore(s, 68) + "..."; end
end

function rmdirIf(p)
if isfolder(p), rmdir(p, 's'); end
end
