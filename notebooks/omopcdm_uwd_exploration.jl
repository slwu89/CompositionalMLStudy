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
# db_death = execute(conn, "SELECT * FROM death;") |> DataFrame empty?
# db_visit_detail = execute(conn, "SELECT * FROM visit_detail;") |> DataFrame # empty?
db_drug_exposure = execute(conn, "SELECT * FROM drug_exposure;") |> DataFrame
db_procedure_occurrence = execute(conn, "SELECT * FROM procedure_occurrence;") |> DataFrame
# db_device_exposure = execute(conn, "SELECT * FROM device_exposure;") |> DataFrame
db_measurement = execute(conn, "SELECT * FROM measurement;") |> DataFrame
db_observation = execute(conn, "SELECT * FROM observation;") |> DataFrame
# db_note = execute(conn, "SELECT * FROM note;") |> DataFrame
# db_note_nlp = execute(conn, "SELECT * FROM note_nlp;") |> DataFrame
# db_episode = execute(conn, "SELECT * FROM episode;") |> DataFrame # not present?
# db_episode_event = execute(conn, "SELECT * FROM episode_event;") |> DataFrame
# db_specimen = execute(conn, "SELECT * FROM specimen;") |> DataFrame
# db_fact_relationship = execute(conn, "SELECT * FROM fact_relationship;") |> DataFrame

# red tables
# db_location = execute(conn, "SELECT * FROM location;") |> DataFrame
# db_care_site = execute(conn, "SELECT * FROM care_site;") |> DataFrame
# db_provider = execute(conn, "SELECT * FROM provider;") |> DataFrame

db_person.person_id = Int.(db_person.person_id)
db_visit_occurrence.visit_occurrence_id = Int.(db_visit_occurrence.visit_occurrence_id)
db_visit_occurrence.person_id = Int.(db_visit_occurrence.person_id)
db_condition_occurrence.person_id = Int.(db_condition_occurrence.person_id)
db_condition_occurrence.visit_occurrence_id = map(x -> ismissing(x) ? x : Int(x), db_condition_occurrence.visit_occurrence_id)

# delete rows with invalid foreign key col
deleteat!(
    db_condition_occurrence,
    ismissing.(db_condition_occurrence.visit_occurrence_id)
)

# the foreign key columns map into the foreign key column, but Catlab/ACSets can only use "part ID" (sequential integers)
# as the "primary key" of each table, so we need to remap them so they point at the row of the corresponding table rather
# than the "primary key" column. Now the primary keys are the row numbers. 

# VisitOccurrence -> Person
db_visit_occurrence.person_id = map(x -> findfirst(db_person.person_id .== x), db_visit_occurrence.person_id)

# ConditionOccurrence -> Person
db_condition_occurrence.person_id = map(x -> findfirst(db_person.person_id .== x), db_condition_occurrence.person_id)

# ConditionOccurrence -> VisitOccurrrence
db_condition_occurrence.visit_occurrence_id = map(x -> findfirst(db_visit_occurrence.visit_occurrence_id .== x), db_condition_occurrence.visit_occurrence_id)

deleteat!(
    db_condition_occurrence,
    isnothing.(db_condition_occurrence.visit_occurrence_id)
)

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

add_parts!(
    omop_acs, :ConditionOccurrence, nrow(db_condition_occurrence), 
    condition_person=db_condition_occurrence.person_id, condition_visit=db_condition_occurrence.visit_occurrence_id
)

# use a UWD to create conjunctive query to retrieve complete data set for an individual
person_query = @relation (Person=p_id, PersonDOB=p_dob, Visit=v_id, Condition=c_id) begin
    Person(_id=p_id, dob=p_dob)
    VisitOccurrence(_id=v_id, visit_person=p_id)
    ConditionOccurrence(_id=c_id, condition_visit=v_id, condition_person=p_id)
end

# all rows
query(omop_acs, person_query)

# a specific person
query(omop_acs, person_query, (p_id=146,))