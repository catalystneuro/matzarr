function ensure_mex()
%ENSURE_MEX Build h5chunks_mex (against MATLAB's bundled libhdf5) if absent.

if ~isempty(which('h5chunks_mex'))
    return
end
root = fileparts(fileparts(fileparts(mfilename('fullpath'))));  % repo root
src = fullfile(root, 'mex', 'h5chunks_mex.c');

% MATLAB's arch dir has libhdf5 under platform-specific (often versioned-
% only) names; find the real file and link it by full path.
archDir = fullfile(matlabroot, 'bin', computer('arch'));
cands = [dir(fullfile(archDir, 'libhdf5.so*')); ...
         dir(fullfile(archDir, 'libhdf5*.dylib'))];
names = string({cands.name});
% exclude the high-level and legacy 1.8 libraries
names = names(~contains(names, "_hl") & ~contains(names, "-1.8"));
if isempty(names)
    error("matzarr:BuildError", ...
        "Could not find MATLAB's bundled libhdf5 in %s.", archDir);
end
names = sort(names);  % prefer the unversioned name when present
lib = fullfile(archDir, char(names(find(names == "libhdf5.dylib" | ...
    names == "libhdf5.so", 1, 'first'))));
if isempty(lib) || ~isfile(lib)
    lib = fullfile(archDir, char(names(1)));
end

mex('-silent', src, lib, '-outdir', root);
rehash;
end
