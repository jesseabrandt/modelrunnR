This is a tool for running code and tracking it along with its inputs and outputs. It is motivated by data science workflows. It can be a flexible general purpose tool (many uses may fall out of the design). But the core motivating workflow is twofold:

1: Me

I am doing a highly swappable demo of this in final_practicum to produce the analysis in Practicum_AI_Branch (both workspace folders), but better, using this package, no panelmodeler, more hyperparameter tuning, easy to understand research repo.

2: Other User

Data scientist realizes their ad hoc modelling scripts are building up and getting confusing, plus run times are expanding and data may be getting larger, and it doesn't always fit in memory!

They add the package. Very easy, intuitive. They can replace their input (maybe read_csv) and output functions (maybe write_csv, or maybe they were just graphing accuracy and throwing away results) with grab() and stow(), then they wrap code in launch() and now several of their problems have been solved. Now all their data is in duckdb and can be queried lazily. Now the system can figure out what has changed and what might need to rerun. The code itself that ran is tracked. They have composable pipelines and a system that understands their pipeline structure, what depends on what.

But on top of that, if they decide to dig deeper, grab and stow can operate as swapout points for anything - data, features, scripts.

Notes:

There may be requirements and implied requirements not mentioned here. Cleaning out old runs matters and should be easy.

The package should integrate well with existing R packages.
