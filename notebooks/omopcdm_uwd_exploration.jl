# Example of OMOP CDM Data

## Dependency Set-Up

using DrWatson
@quickactivate "CompositionalMLStudy"

using DataFrames

import DBInterface:
    execute

import DrWatson:
  datadir

import SQLite:
    DB

## Setting Constants

# OMOP CDM Data Directory
OMOPCDM_DIR = datadir("exp_raw", "OMOPCDM")

# OMOP CDM Example Data 
DATABASE_FILE = "eunomia.sqlite"

## Basic Exploration of IPUMS Data

### Creating Connection to SQLite Database

conn = DB(joinpath(OMOPCDM_DIR, DATABASE_FILE))

### Examining Data

# List out all tables from the OMOP CDM sample database:

sql =
    """
    SELECT name AS TABLE_NAME 
    FROM sqlite_master 
    WHERE type = 'table' 
    ORDER BY name;
    """

db_tables = DataFrame(execute(conn, sql))

# extract the tables we need
db_person = execute(conn, "SELECT * FROM person;") |> DataFrame
db_visit_occurrence = execute(conn, "SELECT * FROM visit_occurrence;") |> DataFrame
db_condition_occurrence = execute(conn, "SELECT * FROM condition_occurrence;") |> DataFrame

db_person.person_id = Int.(db_person.person_id)
db_visit_occurrence.person_id = Int.(db_visit_occurrence.person_id)
db_condition_occurrence.person_id = Int.(db_condition_occurrence.person_id)

# need to subset to the part of the data which will be internally consistent
people_id = intersect(db_visit_occurrence.person_id, db_condition_occurrence.person_id)

filter!(:person_id => x -> x ∈ people_id , db_person)
filter!(:person_id => x -> x ∈ people_id , db_visit_occurrence)
filter!(:person_id => x -> x ∈ people_id , db_condition_occurrence)

people_id_remap = Dict([
    id => ix
    for (ix, id) in enumerate(people_id)
])

db_person.person_id = [people_id_remap[id] for id in db_person.person_id]
db_visit_occurrence.person_id = [people_id_remap[id] for id in db_visit_occurrence.person_id]
db_condition_occurrence.person_id = [people_id_remap[id] for id in db_condition_occurrence.person_id]

# acset stuff
using Catlab
using Dates

@present SchOMOP(FreeSchema) begin
    (Person,VisitOccurrence,ConditionOccurrence)::Ob
    visit_person::Hom(VisitOccurrence,Person)
    condition_person::Hom(ConditionOccurrence,Person)
    condition_visit::Hom(ConditionOccurrence,VisitOccurrence)
    compose(condition_visit, visit_person) == condition_person

    Date::AttrType
    dob::Attr(Person,Date) 
end

to_graphviz(SchOMOP, graph_attrs=Dict(:size=>"4",:ratio=>"expand"))

@acset_type OMOP(SchOMOP, index=[:visit_person,:condition_person,:condition_visit])

omop_acs = OMOP{Date}()

for p in eachrow(db_person)
    add_part!(
        omop_acs, :Person, dob=Date(Int(p.year_of_birth), Int(p.month_of_birth), Int(p.day_of_birth))
    )
end

add_parts!(omop_acs, :VisitOccurrence, nrow(db_visit_occurrence), visit_person=db_visit_occurrence.person_id)
for x in eachrow(db_condition_occurrence)
    if !ismissing(x.visit_occurrence_id) && Int(x.visit_occurrence_id) <= nparts(omop_acs, :VisitOccurrence)
        add_part!(
            omop_acs, :ConditionOccurrence,
            condition_person=x.person_id, condition_visit=Int(x.visit_occurrence_id)
        
        )
    end
end