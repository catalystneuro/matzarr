classdef File < handle & matlab.mixin.indexing.RedefinesDot
    %FILE A .mat file viewed through its matzarr index.
    %   Variables are accessed as properties: f.myVar, f.big(1:100, :).
    %   Reconstruction follows the MATLAB_class conventions of v7.3 files.

    properties (SetAccess = private)
        store
        root      % zarr.Group (consolidated: lookups need no extra reads)
    end

    methods
        function obj = File(store)
            obj.store = store;
            obj.root = zarr.open(store);
        end

        function names = who(obj)
            [arrayNames, groupNames] = obj.root.children();
            names = sort([arrayNames; groupNames]);
            names = names(names ~= "#refs#");
        end

        function val = getVariable(obj, name)
            val = obj.materialize(obj.root.item(name));
        end

        function disp(obj)
            fprintf('  matzarr.File (%s)\n', class(obj.store));
            names = obj.who();
            for i = 1:numel(names)
                fprintf('    %s\n', names(i));
            end
        end
    end

    methods (Access = protected)
        function varargout = dotReference(obj, indexOp)
            v = obj.getVariable(string(indexOp(1).Name));
            if isscalar(indexOp)
                varargout{1} = v;
            else
                varargout{1} = v.(indexOp(2:end));
            end
        end

        function obj = dotAssign(obj, ~, ~)
            error("matzarr:ReadOnly", "matzarr files are read-only.");
        end

        function n = dotListLength(~, ~, ~)
            n = 1;
        end
    end

    methods (Access = private)
        function val = materialize(obj, node)
            if isa(node, 'zarr.Group')
                a = node.attrs;
                gcls = "struct";
                if isfield(a, 'MATLAB_class')
                    gcls = string(char(a.MATLAB_class));
                end
                if gcls ~= "struct"
                    % function handles, classdef objects, tables, ...
                    error("matzarr:UnsupportedClass", ...
                        "Variables of class '%s' are not supported ('%s').", ...
                        gcls, node.path);
                end
                val = obj.materializeStruct(node);
                return
            end
            attrs = node.attrs;
            cls = "";
            if isfield(attrs, 'MATLAB_class')
                cls = string(char(attrs.MATLAB_class));
            end

            if isfield(attrs, 'MATLAB_empty') && attrs.MATLAB_empty
                dims = double(node.read());
                val = emptyOf(cls, reshape(dims, 1, []));
                return
            end

            switch cls
                case {"double", "single", "int8", "int16", "int32", "int64", ...
                      "uint8", "uint16", "uint32", "uint64"}
                    val = node;   % lazy: a zarr.Array with the right class
                case "char"
                    val = char(node.read());
                case "logical"
                    val = logical(node.read());
                case "cell"
                    val = obj.materializeCell(node);
                case ""
                    if isfield(attrs, 'zarr_dtype') && string(char(attrs.zarr_dtype)) == "object"
                        val = obj.materializeCell(node);   % bare refs array
                    else
                        val = node;
                    end
                otherwise
                    error("matzarr:UnsupportedClass", ...
                        "Variables of class '%s' are not supported yet ('%s').", ...
                        cls, node.path);
            end
        end

        function c = materializeCell(obj, node)
            refs = node.read();
            c = cell(size(refs));
            for i = 1:numel(refs)
                r = jsondecode(char(refs(i)));
                target = zarr.internal.normalize_path(string(r.path));
                v = obj.materialize(obj.root.item(target));
                if isa(v, 'zarr.Array')
                    v = v.read();   % cells are fully materialized
                end
                c{i} = v;
            end
        end

        function s = materializeStruct(obj, g)
            [arrayNames, groupNames] = g.children();
            fields = [arrayNames; groupNames];
            % Struct arrays store each field as a bare reference array; a
            % scalar struct stores fields directly (with MATLAB_class).
            vals = cell(1, numel(fields));
            isRefField = false(1, numel(fields));
            for i = 1:numel(fields)
                node = g.item(fields(i));
                if isa(node, 'zarr.Array')
                    a = node.attrs;
                    isRefField(i) = ~isfield(a, 'MATLAB_class') && ...
                        isfield(a, 'zarr_dtype');
                end
                v = obj.materialize(node);
                if isa(v, 'zarr.Array'), v = v.read(); end
                vals{i} = v;
            end
            if ~isempty(fields) && all(isRefField)
                % struct array: every field is a cell of per-element values
                sz = size(vals{1});
                s = repmat(struct(), sz);
                for i = 1:numel(fields)
                    for k = 1:numel(vals{i})
                        s(k).(fields(i)) = vals{i}{k};
                    end
                end
            else
                s = struct();
                for i = 1:numel(fields)
                    s.(fields(i)) = vals{i};
                end
            end
        end
    end
end

function val = emptyOf(cls, dims)
switch cls
    case "char"
        val = char(zeros(dims));
    case "cell"
        val = cell(dims);
    case "logical"
        val = false(dims);
    case ""
        val = zeros(dims);
    otherwise
        val = zeros(dims, char(cls));
end
end
