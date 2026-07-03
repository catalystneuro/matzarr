function probe_layouts()
work = fullfile(tempdir, 'matzarr_layout');
if isfolder(work), rmdir(work, 's'); end
mkdir(work);
[matPath, ~] = TestMatzarr.makeMat(work);
fid = H5F.open(matPath, 'H5F_ACC_RDONLY', 'H5P_DEFAULT');
info = h5info(matPath);
[vMaj, vMin, vRel] = H5.get_libversion();
fprintf('hdf5 %d.%d.%d\n', vMaj, vMin, vRel);
for i = 1:numel(info.Datasets)
    d = info.Datasets(i);
    dset = H5D.open(fid, ['/' d.Name]);
    plist = H5D.get_create_plist(dset);
    layout = H5P.get_layout(plist);  % 0=compact 1=contig 2=chunked
    names = ["compact", "contiguous", "chunked"];
    extra = "";
    if layout == 1
        off = H5D.get_offset(dset);
        sz = H5D.get_storage_size(dset);
        mfid = fopen(matPath, 'r');
        fseek(mfid, double(off), 'bof');
        raw0 = fread(mfid, 8, '*uint8')';
        fseek(mfid, double(off) + 512, 'bof');
        raw512 = fread(mfid, 8, '*uint8')';
        fclose(mfid);
        extra = sprintf(' off=%d size=%d @off=%s @off+512=%s', off, sz, ...
            strjoin(string(dec2hex(raw0, 2))', ' '), ...
            strjoin(string(dec2hex(raw512, 2))', ' '));
    end
    fprintf('%-10s %-11s%s\n', d.Name, names(layout + 1), extra);
    H5D.close(dset);
end
H5F.close(fid);
end
