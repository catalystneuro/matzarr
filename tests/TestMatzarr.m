classdef TestMatzarr < matlab.unittest.TestCase
    %Round trips: MATLAB save -v7.3 -> matzarr.index -> matzarr.open.
    %   The oracle is MATLAB itself: everything read through the index must
    %   isequaln what was saved.

    properties
        work
    end

    methods (TestMethodSetup)
        function makeWork(tc)
            tc.work = fullfile(tempdir, "matzarr_t_" + string(feature('getpid')) + ...
                "_" + string(randi(1e9)));
            mkdir(tc.work);
        end
    end

    methods (TestMethodTeardown)
        function rmWork(tc)
            if isfolder(tc.work), rmdir(tc.work, 's'); end
        end
    end

    methods (Static)
        function [matPath, vars] = makeMat(work)
            vars = struct();
            vars.big = reshape((1:3e5) * 0.25, [500 600]);   % chunked + deflate
            vars.smallD = magic(5);
            vars.vec = (1:100)';
            vars.i32 = int32(reshape(1:24, [4 6]));
            vars.u8 = uint8(255 * ones(3, 3));
            vars.f32 = single(peaks(32));
            vars.scalarV = 42.5;
            vars.ch = 'hello matzarr';
            vars.lg = logical([1 0 1; 0 1 0]);
            vars.c = {int16([1 2 3]), 'text', {'nested', 7}};
            vars.s = struct('x', (1:10)', 'name', 'abc', 'flag', true);
            vars.sArr = struct('a', {1, 2, 3}, 'b', {'x', 'yy', 'zzz'});
            vars.z64 = complex(magic(4), -magic(4));
            vars.z32 = single(complex(peaks(20), fliplr(peaks(20))));
            vars.zscalar = 3 - 4i;
            vars.zvec = (1:50)' + 1i * (51:100)';
            vars.zcell = {1 + 2i, complex(single([1 2 3]), [4 5 6])};
            vars.emptyD = [];
            vars.emptyC = 'x'; vars.emptyC(1) = []; %#ok<NASGU>
            matPath = char(fullfile(work, 'data.mat'));
            save(matPath, '-struct', 'vars', '-v7.3');
        end

        function writeCompound(filePath, dsName, members)
            % An HDF5 file holding one compound dataset. members is
            % {name1, h5type1, name2, h5type2, ...}, packed in order. Only
            % the datatype matters here: the indexer rejects the dataset
            % before it ever looks at storage, so no data is written.
            sizes = zeros(1, numel(members) / 2);
            for i = 1:numel(sizes)
                sizes(i) = H5T.get_size(members{2 * i});
            end
            tid = H5T.create('H5T_COMPOUND', sum(sizes));
            off = 0;
            for i = 1:numel(sizes)
                H5T.insert(tid, members{2 * i - 1}, off, members{2 * i});
                off = off + sizes(i);
            end
            fid = H5F.create(filePath, 'H5F_ACC_TRUNC', 'H5P_DEFAULT', 'H5P_DEFAULT');
            sid = H5S.create_simple(1, 4, 4);
            did = H5D.create(fid, dsName, tid, sid, 'H5P_DEFAULT');
            H5D.close(did);
            H5S.close(sid);
            H5T.close(tid);
            H5F.close(fid);
        end

        function verifyVars(tc, f, vars)
            fn = fieldnames(vars);
            for i = 1:numel(fn)
                name = fn{i};
                got = f.getVariable(name);
                if isa(got, 'zarr.Array')
                    got = got.read();
                end
                tc.verifyTrue(isequaln(got, vars.(name)), ...
                    sprintf('%s mismatch (got %s)', name, class(got)));
            end
        end
    end

    methods (Test)
        function fullRoundTrip(tc)
            [matPath, vars] = TestMatzarr.makeMat(tc.work);
            indexDir = matzarr.index(matPath);
            f = matzarr.open(indexDir);
            tc.verifyTrue(all(ismember(string(fieldnames(vars)), f.who())));
            TestMatzarr.verifyVars(tc, f, vars);
        end

        function lazySlicing(tc)
            [matPath, vars] = TestMatzarr.makeMat(tc.work);
            f = matzarr.open(matzarr.index(matPath));
            v = f.big;
            tc.verifyClass(v, 'zarr.Array');   % lazy, not loaded
            tc.verifyEqual(v(100:120, 200:210), vars.big(100:120, 200:210));
            tc.verifyEqual(f.big(end, end), vars.big(end, end));
            tc.verifyEqual(f.i32(2, 3), vars.i32(2, 3));
        end

        function readOverHttp(tc)
            tc.assumeTrue(isunix, 'http.server test runs on unix only');
            [matPath, vars] = TestMatzarr.makeMat(tc.work);
            matzarr.index(matPath);

            port = 8300 + randi(500);
            cmd = sprintf('python3 -m http.server %d --bind 127.0.0.1 --directory "%s" >/dev/null 2>&1 & echo $!', ...
                port, tc.work);
            [~, pidStr] = system(cmd);
            killer = onCleanup(@() system(sprintf('kill %s >/dev/null 2>&1', strtrim(pidStr))));
            reachable = false;
            for attempt = 1:20
                if system(sprintf('curl -s -o /dev/null --max-time 1 http://127.0.0.1:%d/data.mat.zarr/zarr.json', port)) == 0
                    reachable = true;
                    break
                end
                pause(0.25);
            end
            tc.assumeTrue(reachable, 'local HTTP server not reachable');

            f = matzarr.open(sprintf("http://127.0.0.1:%d/data.mat.zarr", port));
            tc.verifyEqual(f.big(1:10, 1:10), vars.big(1:10, 1:10));
            tc.verifyTrue(isequaln(f.getVariable('c'), vars.c));
            tc.verifyTrue(isequaln(f.getVariable('sArr'), vars.sArr));
        end

        function unsupportedTypesErrorClearly(tc)
            data.fh = @sin; %#ok<STRNU>
            matPath = char(fullfile(tc.work, 'fh.mat'));
            warnState = warning('off', 'MATLAB:save:sizeTooBigForMATFile');
            cleaner = onCleanup(@() warning(warnState));
            save(matPath, '-struct', 'data', '-v7.3');
            % indexing may succeed (function handles are stored as opaque
            % structures); reading the variable must fail clearly, not corrupt
            try
                f = matzarr.open(matzarr.index(matPath));
                tc.verifyError(@() f.getVariable('fh'), "matzarr:UnsupportedClass");
            catch err
                tc.verifyTrue(startsWith(string(err.identifier), "matzarr:"), ...
                    'indexer error is a named matzarr error');
            end
        end

        function requestCounts(tc)
            % The cloud-efficiency contract: opening costs a fixed number of
            % metadata reads; a slice costs exactly its intersecting chunks.
            [matPath, vars] = TestMatzarr.makeMat(tc.work);
            indexDir = matzarr.index(matPath);
            store = CountingManifestStore(indexDir);
            f = matzarr.File(store);
            store.resetCounts();

            v = f.big;                       % consolidated: no reads at all
            tc.verifyEqual(store.nGets + store.nPartials, 0, ...
                'variable lookup is served from consolidated metadata');

            cs = v.chunkShape;
            slice = v(1:10, 1:10); %#ok<NASGU>
            nTouched = prod(ceil(10 ./ min(cs, 10)));
            tc.verifyEqual(store.nGets, nTouched, ...
                sprintf('a 10x10 slice reads exactly %d chunk(s)', nTouched));
        end

        function nocompressionContiguous(tc)
            % save -nocompression produces CONTIGUOUS datasets, exercising
            % the H5D.get_offset path and its offset-semantics validation.
            data.raw = reshape((1:5e4) * 2, [200 250]);
            data.rawVec = int32((1:5000)');
            matPath = char(fullfile(tc.work, 'nc.mat'));
            save(matPath, '-struct', 'data', '-v7.3', '-nocompression');
            f = matzarr.open(matzarr.index(matPath));
            tc.verifyEqual(f.raw(50:60, 100:110), data.raw(50:60, 100:110));
            got = f.rawVec;
            tc.verifyEqual(got.read(), data.rawVec);
        end

        function caseCollidingRefs(tc)
            % .mat /#refs# names are case-sensitive (a..z, A..Z, ...): a cell
            % with >26 entries forces names like 'A' that collide with 'a' on
            % case-insensitive filesystems (macOS APFS). Regression for the
            % silent cross-read that caused.
            c = cell(1, 40);
            for i = 1:40, c{i} = i * (1:i); end   % distinct sizes and values
            data.c = c;
            data.mixed = struct('n', num2cell(1:30), 's', repmat({'x'}, 1, 30));
            matPath = char(fullfile(tc.work, 'refs.mat'));
            save(matPath, '-struct', 'data', '-v7.3');
            f = matzarr.open(matzarr.index(matPath));
            tc.verifyTrue(isequaln(f.getVariable('c'), c));
            tc.verifyTrue(isequaln(f.getVariable('mixed'), data.mixed));
        end

        function structOfCellsAndStructArray(tc)
            % crcns-style: struct with a cell of variable-length arrays plus
            % a struct array, all sharing one /#refs# group.
            data.s.spikes = arrayfun(@(u) sort((1:u*13) * 0.5), 1:15, ...
                'UniformOutput', false);
            data.s.trials = struct('onset', num2cell((1:20) * 2.0), ...
                'label', repmat({'go', 'nogo'}, 1, 10));
            data.s.meta = struct('fs', 30000, 'region', 'CA1');
            matPath = char(fullfile(tc.work, 'ephys.mat'));
            save(matPath, '-struct', 'data', '-v7.3');
            f = matzarr.open(matzarr.index(matPath));
            tc.verifyTrue(isequaln(f.getVariable('s'), data.s));
        end

        function indexAwayFromFile(tc)
            % index dir not adjacent to the .mat: relative path must still
            % resolve (regression for hardcoded ../name.mat).
            [matPath, vars] = TestMatzarr.makeMat(tc.work);
            idx = fullfile(tc.work, "sub", "dir", "out.zarr");
            matzarr.index(matPath, idx);
            f = matzarr.open(idx);
            tc.verifyEqual(f.big(1:5, 1:5), vars.big(1:5, 1:5));
        end

        function twoFileIndex(tc)
            % the on-disk index is exactly two files (consolidated root +
            % manifest), regardless of node count.
            data.a.b.c = magic(4); data.a.b.d = (1:100)'; data.x = pi;
            matPath = char(fullfile(tc.work, 'deep.mat'));
            save(matPath, '-struct', 'data', '-v7.3');
            idx = matzarr.index(matPath);
            files = dir(fullfile(idx, '**', '*')); files = files(~[files.isdir]);
            tc.verifyEqual(sort(string({files.name})), ["manifest.json", "zarr.json"]);
        end

        function complexRoundTrip(tc)
            % MATLAB writes complex arrays as an HDF5 compound {real, imag},
            % which is byte-for-byte Zarr's complex64/complex128 — so complex
            % chunks are byte-range views, never re-encoded. Cover both
            % layouts: chunked + deflate, and contiguous (-nocompression).
            data.zbig = complex(reshape((1:1.2e5) * 0.5, [300 400]), ...
                                reshape((1:1.2e5) * -0.25, [300 400]));
            data.zs.field = (1:20) + 1i * (21:40);
            data.zsArr = struct('v', {1 + 1i, 2 - 2i, complex(single(3), 4)});
            data.zmix = complex([1 NaN Inf -Inf], [NaN 0 -Inf Inf]);
            data.z32 = single(complex(peaks(16), -peaks(16)));
            matPath = char(fullfile(tc.work, 'z.mat'));
            save(matPath, '-struct', 'data', '-v7.3');
            ncPath = char(fullfile(tc.work, 'znc.mat'));
            save(ncPath, '-struct', 'data', '-v7.3', '-nocompression');

            for p = string({matPath, ncPath})
                f = matzarr.open(matzarr.index(p));
                v = f.zbig;
                tc.verifyClass(v, 'zarr.Array');          % lazy, like any numeric
                tc.verifyEqual(v.dtype, "complex128");
                tc.verifyEqual(v(50:60, 100:110), data.zbig(50:60, 100:110), ...
                    sprintf('zbig slice (%s)', p));
                tc.verifyTrue(isequaln(v.read(), data.zbig));
                tc.verifyTrue(isequaln(f.getVariable('zs'), data.zs));
                tc.verifyTrue(isequaln(f.getVariable('zsArr'), data.zsArr));
                zmix = f.getVariable('zmix');
                tc.verifyClass(zmix, 'zarr.Array');       % complex stays lazy too
                tc.verifyTrue(isequaln(zmix.read(), data.zmix), ...
                    'NaN/Inf survive in both parts');
                tc.verifyEqual(f.z32.dtype, "complex64");
            end
        end

        function nonComplexCompoundErrorsClearly(tc)
            % Only MATLAB's {real, imag} form of compound is supported. Any
            % other record type must be named and refused, not misread as
            % complex. Built with the low-level API: MATLAB itself has no
            % way to save an arbitrary compound.
            cases = {
                {'rec', {'x', 'H5T_IEEE_F64LE', 'n', 'H5T_STD_I32LE'}}
                {'intri', {'real', 'H5T_STD_I32LE', 'imag', 'H5T_STD_I32LE'}}
            };
            for k = 1:numel(cases)
                name = cases{k}{1};
                members = cases{k}{2};
                h5Path = char(fullfile(tc.work, [name '.mat']));
                TestMatzarr.writeCompound(h5Path, name, members);
                tc.verifyError(@() matzarr.index(h5Path, ...
                    fullfile(tc.work, string(name) + ".zarr")), "matzarr:UnsupportedType");
            end
        end

        function readOnly(tc)
            [matPath, ~] = TestMatzarr.makeMat(tc.work);
            f = matzarr.open(matzarr.index(matPath));
            function assignVar()
                f.big = 5;
            end
            tc.verifyError(@assignVar, "matzarr:ReadOnly");
        end
    end
end
