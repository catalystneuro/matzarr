function f = open(indexPath)
%OPEN Open a matzarr index (local directory or URL) for reading.
%   f = matzarr.open("data.mat.zarr")
%   f = matzarr.open("https://bucket/data.mat.zarr")
%
%   f.who lists variables; f.<name> returns the variable. Large numeric
%   variables come back as lazy zarr arrays (slice with ordinary indexing
%   to fetch only the chunks you touch); char/logical/cell/struct values
%   are reconstructed eagerly.

f = matzarr.File(zarr.stores.ManifestStore(indexPath));
end
