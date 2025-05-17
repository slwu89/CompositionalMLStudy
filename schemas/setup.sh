#!/bin/bash
#
# File: update-ddl.sh
#
# Converts the OMOP-provided DDL database definition scripts into a format
# that can be loaded by sqlite3.
#
# This has been tested against the provided sqlite 5.4 DDL files.
#
# To run this, place copies of the provided .sql files into this directory
# and run the script. It will modify the sql files and create an empty
# database called cdm.db

wget https://raw.githubusercontent.com/OHDSI/CommonDataModel/refs/heads/main/inst/ddl/5.4/sqlite/OMOPCDM_sqlite_5.4_constraints.sql
wget https://raw.githubusercontent.com/OHDSI/CommonDataModel/refs/heads/main/inst/ddl/5.4/sqlite/OMOPCDM_sqlite_5.4_ddl.sql
wget https://raw.githubusercontent.com/OHDSI/CommonDataModel/refs/heads/main/inst/ddl/5.4/sqlite/OMOPCDM_sqlite_5.4_indices.sql
wget https://raw.githubusercontent.com/OHDSI/CommonDataModel/refs/heads/main/inst/ddl/5.4/sqlite/OMOPCDM_sqlite_5.4_primary_keys.sql

set -euo pipefail

# Find the DDL file
DDL=$(ls OMOPCDM*_ddl.sql 2>/dev/null || true)
[ -z "${DDL}" ] && echo "❌ Failed to find an OMOPCDM*_ddl.sql schema!" && exit 1

##
# Get the table and primary key columns from *_primary_keys.sql
##
function get_pks() {
  grep '^ALTER TABLE ' OMOPCDM*_primary_keys.sql \
    | sed -E 's:.*ALTER TABLE ([^ ]+) ADD CONSTRAINT [^ ]+ PRIMARY KEY \(([^)]+)\);:\1 \2:'
}

##
# Get the table, column, and reference from *_constraints.sql
##
function get_fks() {
  grep '^ALTER TABLE ' OMOPCDM*_constraints.sql \
    | sed -E 's:ALTER TABLE ([^ ]+) ADD CONSTRAINT [^ ]+ FOREIGN KEY \(([^)]+)\) REFERENCES ([^;]+);:\1 \2 \3:'
}

##
# Insert PRIMARY KEY modifier into the column definition
##
function mark_pk() {
  echo "🔧 Marking PRIMARY KEY on $1.$2"
  awk -v table="$1" -v column="$2" '
    BEGIN { target = 0 }
    /^[[:space:]]*CREATE TABLE[[:space:]]+/ {
      if ($0 ~ "CREATE TABLE[[:space:]]*" table "[[:space:]]*\\(") {
        target = 1
      } else {
        target = 0
      }
    }
    {
      if (target && $1 == column && $0 !~ /PRIMARY KEY/) {
        sub(/,/, " PRIMARY KEY,")
      }
      print
    }
  ' "${DDL}" > "${DDL}.tmp"

  if ! cmp -s "${DDL}" "${DDL}.tmp"; then
    mv "${DDL}.tmp" "${DDL}"
  else
    echo "⚠️ Skipping $1.$2 — already has PRIMARY KEY or column not found."
    rm -f "${DDL}.tmp"
  fi
}

##
# Insert FOREIGN KEY constraint into the column definition
##
function mark_fk() {
  echo "🔧 Marking FOREIGN KEY on $1.$2 → $3"
  awk -v table="$1" -v column="$2" -v ref="$3" '
    BEGIN { target = 0 }
    /^[[:space:]]*CREATE TABLE[[:space:]]+/ {
      if ($0 ~ "CREATE TABLE[[:space:]]*" table "[[:space:]]*\\(") {
        target = 1
      } else {
        target = 0
      }
    }
    {
      if (target && $1 == column && $0 !~ /REFERENCES/) {
        if ($0 ~ /,$/) {
          sub(/,$/, " REFERENCES " ref ",")
        } else {
          sub(/[[:space:]]*\);$/, " REFERENCES " ref ");")
        }
      }
      print
    }
  ' "${DDL}" > "${DDL}.tmp"

  if ! cmp -s "${DDL}" "${DDL}.tmp"; then
    mv "${DDL}.tmp" "${DDL}"
  else
    echo "⚠️ Skipping $1.$2 — already has FOREIGN KEY or column not found."
    rm -f "${DDL}.tmp"
  fi
}

# Cleanup the schema placeholder
echo "🧹 Removing schema references"
sed -i -e 's:@cdmDatabaseSchema.::g' OMOPCDM*.sql && rm -f OMOPCDM*.sql-e

# Insert PRIMARY KEYS
echo "🔑 Adding PRIMARY KEYS to DDL"
get_pks | while read -r table column; do
  mark_pk "$table" "$column"
done

# Insert one known missing PK for sqlite foreign key enforcement
echo "🔧 Manually adding missing PK for 'cohort.cohort_definition_id'"
mark_pk cohort cohort_definition_id

# Insert FOREIGN KEYS
echo "🔗 Adding FOREIGN KEYS to DDL"
get_fks | while read -r table column reference; do
  mark_fk "$table" "$column" "$reference"
done

# Create database
echo "📦 Creating empty cdm.db database"
rm -f cdm.db
touch cdm.db
sqlite3 cdm.db < "${DDL}"
sqlite3 cdm.db < OMOPCDM_sqlite_5.4_indices.sql

# Check foreign key constraints
echo "🔍 Checking foreign key integrity"
sqlite3 cdm.db "PRAGMA foreign_key_check"

echo "✅ DONE!"
