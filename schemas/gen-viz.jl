using Catlab

"""
A schema to describe SQL schemas.
`Table` is what you would expect. `Column` are the columns of a table, so they always know who they belong to col_of.
PK is the primary key of a table pk_of. It needs a junction table PK_Cols because composite primary keys need
to reference multiple columns of a table. FK are foreign keys, they take you from one table to a PK (of another table).
Because the referenced primary key may be composite, the foreign key may also need to be composite, so there is a junction
table FK_Cols to relate a foreign key to its columns.

There are 2 commuting squares. The first is defined by pk_col; col_of == pk; pk_of, saying that a primary key's columns
must belong to the table that it is a primary key for. The second is analogous for foreign keys and is defined by fk; from == fk_col; col_of.
We would also like to say that from != to; pk_of so that foreign keys have to go between different tables but I do not know
how to enforce that.

We set injective constraints (via `unique_index` when calling `@acset_type`) on the following homs:
  * `pk_of`: each primary key can only be the PK of a single table
"""
@present TheorySQLSchema(FreeSchema) begin
  (Table, Column, PK, PK_Cols, FK, FK_Cols)::Ob
  col_of::Hom(Column, Table)
  pk_col::Hom(PK_Cols, Column)
  pk::Hom(PK_Cols, PK)
  pk_of::Hom(PK, Table)
  to::Hom(FK, PK)
  from::Hom(FK, Table)
  fk::Hom(FK_Cols, FK)
  fk_col::Hom(FK_Cols, Column)
  Name::AttrType
  tab_name::Attr(Table, Name)
  col_name::Attr(Column, Name)
  col_type::Attr(Column, Name)
  compose(pk, pk_of) == compose(pk_col, col_of)
  compose(fk_col, col_of) == compose(fk, from)
  # compose(to, pk_of) != from
end

to_graphviz(TheorySQLSchema, graph_attrs=Dict(:size=>"4.5",:ratio=>"expand"))

@abstract_acset_type AbstractSQLSchema
@acset_type SQLSchema(
    TheorySQLSchema, 
    index=[:col_of, :pk_col, :pk, :to, :from, :fk, :fk_col], 
    unique_index=[:pk_of]
) <: AbstractSQLSchema

using SQLite, DataFrames

con = DBInterface.connect(SQLite.DB, "cdm.db")

# sch_tables = DBInterface.execute(con, "SELECT * FROM sqlite_schema;") |> DataFrame

sch_tables = DBInterface.execute(con, "PRAGMA main.table_list;") |> DataFrame

sch_fk = Dict([
    let 
        tbl => DBInterface.execute(con, "PRAGMA foreign_key_list('$(tbl)');") |> DataFrame
    end
    for tbl in sch_tables.name
])

sch_pk = Dict([
    let 
        tbl => DBInterface.execute(con, "PRAGMA index_list('$(tbl)');") |> DataFrame
    end
    for tbl in sch_tables.name
])

sch_tbl_info = Dict([
    let 
        tbl => DBInterface.execute(con, "PRAGMA table_info('$(tbl)');") |> DataFrame
    end
    for tbl in sch_tables.name
])

DBInterface.close!(con)


acs_sch = @acset SQLSchema{String} begin
    Table = length(sch_tbl_info)
    tab_name = keys(sch_tbl_info)
end

# add Columns and PKs
for (k,v) in sch_tbl_info
    tab_id = only(incident(acs_sch, k, :tab_name))
    add_parts!(acs_sch, :Column, nrow(v), col_of=tab_id, col_name=v.name, col_type=v.type)
    # pk
    v_pk_id = findall(v.pk .!= 0)
    length(v_pk_id) == 0 && println("tab $k has no PK")
    pk_id = add_parts!(acs_sch, :PK, length(v_pk_id), pk_of=tab_id)
    # pk_cols
    col_id = intersect(
        vcat(incident(acs_sch, v[v_pk_id, :name], :col_name)...),
        incident(acs_sch, tab_id, :col_of)
    )
    add_parts!(acs_sch, :PK_Cols, length(pk_id), pk_col=col_id, pk=pk_id)
end

# add FKs
for (k,v) in sch_fk
    from_tbl = only(incident(acs_sch, k, :tab_name))
    for fk in groupby(v, :id)
        to_pk = only(incident(acs_sch, lowercase(only(unique(fk.table))), (:pk_of, :tab_name)))
        fk_id = add_part!(acs_sch, :FK, from=from_tbl, to=to_pk)
        # fk cols
        fk_cols = intersect(
            vcat(incident(acs_sch, fk.from, :col_name)...),
            incident(acs_sch, from_tbl, :col_of)
        )
        add_parts!(acs_sch, :FK_Cols, nrow(fk), fk=fk_id, fk_col=fk_cols)
    end
end

"""
A dictionary to map the type of a column to an emoji
"""
const schema_col_emoji = Dict(
    "pk" => "🔑",
    "pk/fk" => "🔑🔗",
    "fk" => "🔗",
    "data" => "📊"
)


"""
For a table with part ID `tab_id` get a dataframe
that contains columns necessary to generate the table cells of the HTML node label
"""
function get_cols_table(acs::T, tab_id) where {T<:AbstractSQLSchema}
    # all deepcopys can be replaced when figure out ACSets.jl issue
    tab_cols = deepcopy(incident(acs, tab_id, :col_of))    
    tab_pk = acs[incident(acs, tab_id, (:pk, :pk_of)), :pk_col]
    tab_fk = acs[incident(acs, tab_id, (:fk, :from)), :fk_col]
    tab_pk_fk = intersect(tab_fk, tab_pk)
    setdiff!(tab_fk, tab_pk_fk)
    setdiff!(tab_pk, tab_pk_fk)
    setdiff!(tab_cols, union(tab_fk, tab_pk, tab_pk_fk))

    label_cells_df = DataFrame(
        name=acs[[tab_pk; tab_pk_fk; tab_fk; tab_cols], :col_name],
        type=acs[[tab_pk; tab_pk_fk; tab_fk; tab_cols], :col_type],
        col_guide = label=[fill("pk",length(tab_pk)); fill("pk/fk",length(tab_pk_fk)); fill("fk", length(tab_fk)); fill("data", length(tab_cols))]
    )
    label_cells_df.pk_port = [x.col_guide ∈ ["pk", "pk/fk"] ? """ PORT="pk_$(x.name)" """ : " " for x in eachrow(label_cells_df)]
    label_cells_df.fk_port = [x.col_guide ∈ ["fk", "pk/fk"] ? """ PORT="fk_$(x.name)" """ : " " for x in eachrow(label_cells_df)]
    return label_cells_df
end

"""
Given an acset of schema `SchSqlTables` and a table part ID `tab_id`, generate an HTML-like node label for it.
"""
function make_label_table(acs::T, tab_id) where {T<:AbstractSQLSchema}
    label = String[]
    # name of this table
    tab_name = acs[tab_id, :tab_name]
    # all cols of this table
    tab_cols = get_cols_table(acs, tab_id)
    # make the node header
    push!(label, "$(tab_name) [label=<\n")
    push!(label, """
        <TABLE BORDER="0" CELLSPACING="0" CELLBORDER="1">
            <TR>
                <TD COLSPAN="3" BGCOLOR="#00857C"><FONT COLOR="#FFFFFF" FACE="times-bold">$(tab_name)</FONT></TD>
            </TR>
    """)
    for tr in eachrow(tab_cols)
        push!(label, """
                <TR>
                    <TD$(tr.pk_port)BGCOLOR="#6ECEB2" CELLPADDING="4">$(schema_col_emoji[tr.col_guide])</TD> <TD>$(tr.name)</TD> <TD$(tr.fk_port)>$(tr.type)</TD>
                </TR>
        """)
    end
    # close the table
    push!(label, """
        </TABLE>
    >];
    """)
    return join(label, "")
end

"""
Given an acset of schema `SchSqlTables`, generate all the edges.
"""
function make_edges(acs::T) where {T<:AbstractSQLSchema}
    from_tab = acs[:, (:from, :tab_name)]
    to_tab = acs[:, (:to, :pk_of, :tab_name)]
    from_col = [acs[fk_cols, (:fk_col, :col_name)] for fk_cols in incident(acs, :, :fk)]
    to_col = [acs[pk_cols, (:pk_col, :col_name)] for pk_cols in incident(acs, acs[:, :to], :pk)]
    edges = String[]
    # i indexes over tables
    for i in eachindex(from_tab)
        # j indexes over cols (if a FK goes to a composite PK they have >1 col)
        for j in eachindex(from_col[i])
            push!(edges, "$(from_tab[i]):fk_$(from_col[i][j]):e -> $(to_tab[i]):pk_$(to_col[i][j]):w\n")
        end
    end
    return join(edges, "")
end

"""
Given an acset of schema `SchSqlTables`, generate a string in the Graphviz DOT language
"""
function make_graphviz(acs::T) where {T<:AbstractSQLSchema}
    dot = String[]
    push!(dot, """digraph G {
        graph[rankdir="LR"]
        node[shape="plain"]
    """)
    for t in parts(acs, :Table)
        push!(dot, make_label_table(acs, t))
    end
    push!(dot, make_edges(acs))
    push!(dot, "}")
    return join(dot, "")
end

# make it and visualize
dot_str = make_graphviz(acs_sch)
clipboard(dot_str)