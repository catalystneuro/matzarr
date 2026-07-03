classdef CountingManifestStore < zarr.stores.ManifestStore
    %COUNTINGMANIFESTSTORE ManifestStore that counts data accesses, for tests.

    properties
        nGets (1,1) double = 0
        nPartials (1,1) double = 0
    end

    methods
        function obj = CountingManifestStore(root)
            obj@zarr.stores.ManifestStore(root);
        end

        function [data, found] = get(obj, key)
            if ~endsWith(string(key), ".json")
                obj.nGets = obj.nGets + 1;
            end
            [data, found] = get@zarr.stores.ManifestStore(obj, key);
        end

        function [data, found] = getPartial(obj, key, offset, len)
            obj.nPartials = obj.nPartials + 1;
            [data, found] = getPartial@zarr.stores.ManifestStore(obj, key, offset, len);
        end

        function resetCounts(obj)
            obj.nGets = 0;
            obj.nPartials = 0;
        end
    end
end
