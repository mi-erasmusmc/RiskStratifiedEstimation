#' Prepares for the running the PatientLevelPrediction package
#'
#' Prepares for running the PatientLevelPrediction package by merging the treatment and comparator cohorts and defining a new covariate for treatment.
#'
#' @param treatmentCohortId The treatment cohort id
#' @param comparatorCohortId The comparator cohort id
#' @param targetCohortId The id of the merged cohorts
#' @param cohortDatabaseSchema The name of the database schema that is the location where the cohort data used to define the at risk cohort is available
#' @param cohortTable The table that contains the treatment and comparator cohorts.
#' @param resultsDatabaseSchema The name of the database schema to store the new tables. Need to have write access.
#' @param mergedCohortTable The table that will contain the merged cohorts.
#' @param connectionDetails The connection details required to connect to a database.
#'
#' @return Creates the tables resultsDatabaseSchema.mergedCohortTable, resultsDatabaseSchema.attributeDefinitionTable and resultsDatabaseSchema.cohortAttributeTable
#'
#' @export

prepareForPlpData <- function(treatmentCohortId,
                              comparatorCohortId,
                              targetCohortId,
                              cohortDatabaseSchema,
                              cohortTable,
                              resultsDatabaseSchema,
                              mergedCohortTable,
                              connectionDetails){

  addTable(connectionDetails,
           resultsDatabaseSchema = resultsDatabaseSchema,
           table = mergedCohortTable)

  connection <- DatabaseConnector::connect(connectionDetails)


  renderedSql <- SqlRender::loadRenderTranslateSql("mergeCohorts.sql",
                                                   packageName = "RiskStratifiedEstimation",
                                                   result_database_schema = resultsDatabaseSchema,
                                                   merged_cohort_table = mergedCohortTable,
                                                   cohort_database_schema = cohortDatabaseSchema,
                                                   cohort_table = cohortTable,
                                                   target_cohort_id = targetCohortId,
                                                   cohort_ids = c(treatmentCohortId, comparatorCohortId),
                                                   dbms = connectionDetails$dbms)

  DatabaseConnector::executeSql(connection, renderedSql)
  DatabaseConnector::disconnect(connection)

}



addTable <- function(connectionDetails,
                     resultsDatabaseSchema,
                     table){

  renderedSql <- SqlRender::loadRenderTranslateSql("createTable.sql",
                                                   packageName = "RiskStratifiedEstimation",
                                                   result_database_schema = resultsDatabaseSchema,
                                                   target_cohort_table = table,
                                                   dbms = connectionDetails$dbms)

  connection <- DatabaseConnector::connect(connectionDetails)
  DatabaseConnector::executeSql(connection, renderedSql)
  DatabaseConnector::disconnect(connection)

}




#' @importFrom dplyr %>%
switchOutcome <- function(ps,
                           populationCm){


  result <- ps %>%
    dplyr::select(subjectId, propensityScore) %>%
    dplyr::left_join(populationCm,
                     by = "subjectId") %>%
    dplyr::filter(!is.na(survivalTime))
  return(result)

}




#' Combines the overall results
#'
#' @param analysisSettings           An R object of type \code{analysisSettings} created using the function
#'                                   \code{\link[RiskStratifiedEstimation]{createAnalysisSettings}}.
#' @param runSettings                An R object of type \code{runSettings} created using the function
#'                                   \code{\link[RiskStratifiedEstimation]{createRunSettings}}.
#'
#' @return                          Stores the overall results along with the required data to lauch the shiny
#'                                   application in the `shiny` directory

#' @importFrom dplyr %>%
#' @export

createOverallResults <- function(analysisSettings){

  predictOutcomes <-
    analysisSettings$outcomeIds[which(colSums(analysisSettings$analysisMatrix) != 0)]

  pathToResults <- file.path(analysisSettings$saveDirectory,
                             analysisSettings$analysisId,
                             "Estimation")

  pathToPrediction <- file.path(analysisSettings$saveDirectory,
                                analysisSettings$analysisId,
                                "Prediction")

  saveDir <- file.path(analysisSettings$saveDirectory,
                       analysisSettings$analysisId,
                       "shiny")

  if (!dir.exists(saveDir)) {
    dir.create(saveDir, recursive = T)
  }

  absolute <- data.frame(estimate = numeric(),
                         lower = numeric(),
                         upper = numeric(),
                         riskStratum = character(),
                         stratOutcome = numeric(),
                         estOutcome = numeric(),
                         database = character(),
                         analysisType = character(),
                         treatment = numeric(),
                         comparator = numeric())
  relative <- data.frame(estimate = numeric(),
                         lower = numeric(),
                         upper = numeric(),
                         riskStratum = character(),
                         stratOutcome = numeric(),
                         estOutcome = numeric(),
                         database = character(),
                         analysisType = character(),
                         treatment = numeric(),
                         comparator = numeric())
  cases <- data.frame(riskStratum = character(),
                      stratOutcome = numeric(),
                      estOutcome = numeric(),
                      database = character(),
                      analysisType = character(),
                      treatment = numeric(),
                      comparator = numeric())

  predictonPopulations <- c("EntirePopulation",
                            "Matched",
                            "Treatment",
                            "Comparator")

  for (predictOutcome in predictOutcomes) {

    for (predictionPopulation in predictonPopulations) {

      prediction <- readRDS(
        file.path(
          pathToPrediction,
          predictOutcome,
          analysisSettings$analysisId,
          predictionPopulation,
          "prediction.rds"
        )
      )

      prediction <- prediction[order(-prediction$value), c("value", "outcomeCount")]
      prediction$sens <- cumsum(prediction$outcomeCount) / sum(prediction$outcomeCount)
      prediction$fpRate <- cumsum(prediction$outcomeCount == 0) / sum(prediction$outcomeCount == 0)
      data <- stats::aggregate(fpRate ~ sens, data = prediction, min)
      data <- stats::aggregate(sens ~ fpRate, data = data, min)
      data <- rbind(data, data.frame(fpRate = 1, sens = 1)) %>%
        dplyr::mutate(
          database = analysisSettings$databaseName,
          analysisId = analysisSettings$analysisId,
          stratOutcome = predictOutcome,
          treatmentId = analysisSettings$treatmentCohortId,
          comparatorId = analysisSettings$comparatorCohortId,
          analysisType = analysisSettings$analysisType
        )

      saveRDS(
        data,
        file.path(
          saveDir,
         paste0(
           paste(
             "auc",
             predictionPopulation,
             analysisSettings$analysisId,
             analysisSettings$treatmentCohortId,
             analysisSettings$comparatorCohortId,
             predictOutcome,
             sep = "_"
           ),
           ".rds"
         )
        )
      )

      calibration <- readRDS(
        file.path(
          pathToPrediction,
          predictOutcome,
          analysisSettings$analysisId,
          predictionPopulation,
          "performanceEvaluation.rds"
        )
      )

      calibration$calibrationSummary %>%
        dplyr::select(
          averagePredictedProbability,
          observedIncidence,
          PersonCountAtRisk
        ) %>%
        dplyr::rowwise() %>%
        dplyr::mutate(
          lower = binom.test(
            x = observedIncidence*PersonCountAtRisk,
            PersonCountAtRisk
          )$conf.int[1],
          upper = binom.test(
            x = observedIncidence*PersonCountAtRisk,
            PersonCountAtRisk
          )$conf.int[2]
        ) %>%
        dplyr::mutate(
          database = analysisSettings$databaseName,
          analysisId = analysisSettings$analysisId,
          stratOutcome = predictOutcome,
          treatmentId = analysisSettings$treatmentCohortId,
          comparatorId = analysisSettings$comparatorCohortId,
          analysisType = analysisSettings$analysisType
        ) %>%
        as.data.frame() %>%
        saveRDS(
          file.path(
            saveDir,
            paste0(
              paste(
                "calibration",
                predictionPopulation,
                analysisSettings$analysisId,
                analysisSettings$treatmentCohortId,
                analysisSettings$comparatorCohortId,
                predictOutcome,
                sep = "_"
              ),
              ".rds"
            )
          )
        )


    }

    absoluteResult <- readRDS(file.path(pathToResults,
                                        predictOutcome,
                                        "absoluteRiskReduction.rds")) %>%
      dplyr::rename("estimate" = "ARR")
    absoluteResult <- data.frame(absoluteResult,
                                 stratOutcome = predictOutcome,
                                 estOutcome = predictOutcome,
                                 database = analysisSettings$databaseName,
                                 analysisType = analysisSettings$analysisType,
                                 treatment = analysisSettings$treatmentCohortId,
                                 comparator = analysisSettings$comparatorCohortId)
    absolute <- rbind(absolute, absoluteResult)

    relativeResult <- readRDS(file.path(pathToResults,
                                        predictOutcome,
                                        "relativeRiskReduction.rds")) %>%
      dplyr::rename("estimate" = "HR")
    relativeResult <- data.frame(relativeResult,
                                 stratOutcome = predictOutcome,
                                 estOutcome = predictOutcome,
                                 database = analysisSettings$databaseName,
                                 analysisType = analysisSettings$analysisType,
                                 treatment = analysisSettings$treatmentCohortId,
                                 comparator = analysisSettings$comparatorCohortId)
    relative <- rbind(relative, relativeResult)

    casesResult <- readRDS(file.path(pathToResults,
                                     predictOutcome,
                                     "cases.rds")) %>%
      dplyr::rename("casesComparator" = "comparator") %>%
      dplyr::rename("casesTreatment" = "treatment")
    casesResult <- data.frame(casesResult,
                              stratOutcome = predictOutcome,
                              estOutcome = predictOutcome,
                              database = analysisSettings$databaseName,
                              analysisType = analysisSettings$analysisType,
                              treatment = analysisSettings$treatmentCohortId,
                              comparator = analysisSettings$comparatorCohortId)
    cases <- rbind(cases, casesResult)

    predLoc <- which(analysisSettings$outcomeIds == predictOutcome)
    compLoc <- analysisSettings$analysisMatrix[, predLoc]
    compareOutcomes <- analysisSettings$outcomeIds[as.logical(compLoc)]
    compareOutcomes <- compareOutcomes[compareOutcomes != predictOutcome]

    if (length(compareOutcomes) != 0) {
      for (compareOutcome in compareOutcomes) {
        absoluteResult <- readRDS(file.path(pathToResults,
                                            predictOutcome,
                                            compareOutcome,
                                            "absoluteRiskReduction.rds")) %>%
          dplyr::rename("estimate" = "ARR")
        absoluteResult <- data.frame(absoluteResult,
                                     stratOutcome = predictOutcome,
                                     estOutcome = compareOutcome,
                                     database = analysisSettings$databaseName,
                                     analysisType = analysisSettings$analysisType,
                                     treatment = analysisSettings$treatmentCohortId,
                                     comparator = analysisSettings$comparatorCohortId)
        absolute <- rbind(absolute, absoluteResult)

        relativeResult <- readRDS(file.path(pathToResults,
                                            predictOutcome,
                                            compareOutcome,
                                            "relativeRiskReduction.rds")) %>%
          dplyr::rename("estimate" = "HR")
        relativeResult <- data.frame(relativeResult,
                                     stratOutcome = predictOutcome,
                                     estOutcome = compareOutcome,
                                     database = analysisSettings$databaseName,
                                     analysisType = analysisSettings$analysisType,
                                     treatment = analysisSettings$treatmentCohortId,
                                     comparator = analysisSettings$comparatorCohortId)
        relative <- rbind(relative, relativeResult)

        casesResult <- readRDS(file.path(pathToResults,
                                         predictOutcome,
                                         compareOutcome,
                                         "cases.rds")) %>%
          dplyr::rename("casesComparator" = "comparator") %>%
          dplyr::rename("casesTreatment" = "treatment")
        casesResult <- data.frame(casesResult,
                                  stratOutcome = predictOutcome,
                                  estOutcome = compareOutcome,
                                  database = analysisSettings$databaseName,
                                  analysisType = analysisSettings$analysisType,
                                  treatment = analysisSettings$treatmentCohortId,
                                  comparator = analysisSettings$comparatorCohortId)
        cases <- rbind(cases, casesResult)
      }
    }
  }

  absolute %>%
    saveRDS(file.path(saveDir, "mappedOverallAbsoluteResults.rds"))

  relative %>%
    saveRDS(file.path(saveDir, "mappedOverallRelativeResults.rds"))

  cases %>%
    saveRDS(file.path(saveDir, "mappedOverallCasesResults.rds"))

  analysisSettings$mapOutcomes %>%
    dplyr::rename(
      "outcome_id" = "idNumber",
      "outcome_name" = "label"
    ) %>%
    saveRDS(
      file.path(
        saveDir,
        "map_outcomes.rds"
      )
    )

  analysisSettings$mapTreatments %>%
    dplyr::rename(
      "exposure_id" = "idNumber",
      "exposure_name" = "label"
    ) %>%
    saveRDS(
      file.path(
        saveDir,
        "map_exposures.rds"
      )
    )

  data.frame(
    analysis_id = analysisSettings$analysisId,
    description = analysisSettings$description,
    database = analysisSettings$databaseName,
    analysis_type = analysisSettings$analysisType,
    treatment_id = analysisSettings$treatmentCohortId,
    comparator_id = analysisSettings$comparatorCohortId
  ) %>%
    saveRDS(
      file.path(
        saveDir,
        "analyses.rds"
      )
    )



  return(NULL)
}

