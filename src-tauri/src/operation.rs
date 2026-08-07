use serde::Serialize;
use tauri::{Emitter, WebviewWindow};

use crate::error::AppError;

pub struct Operation<'a> {
    id: String,
    window: &'a WebviewWindow,
}

#[derive(Clone, Serialize)]
#[serde(rename_all = "camelCase")]
struct OperationUpdate<'a> {
    update_type: &'a str,
    step_id: &'a str,
    extra_details: Option<AppError>,
    progress: Option<f32>,
}

impl<'a> Operation<'a> {
    pub fn new(id: String, window: &'a WebviewWindow) -> Operation<'a> {
        Operation { id, window }
    }

    pub fn move_on(&self, old_id: &str, new_id: &str) -> Result<(), AppError> {
        self.complete(old_id)?;
        self.start(new_id)
    }

    pub fn start(&self, id: &str) -> Result<(), AppError> {
        self.window
            .emit(
                &format!("operation_{}", self.id),
                OperationUpdate {
                    update_type: "started",
                    step_id: id,
                    extra_details: None,
                    progress: None,
                },
            )
            .map_err(|e| AppError::OperationUpdate(e.to_string()))
    }

    pub fn complete(&self, id: &str) -> Result<(), AppError> {
        self.window
            .emit(
                &format!("operation_{}", self.id),
                OperationUpdate {
                    update_type: "finished",
                    step_id: id,
                    extra_details: None,
                    progress: None,
                },
            )
            .map_err(|e| AppError::OperationUpdate(e.to_string()))
    }

    pub fn fail<T>(&self, id: &str, error: AppError) -> Result<T, AppError> {
        self.window
            .emit(
                &format!("operation_{}", self.id),
                OperationUpdate {
                    update_type: "failed",
                    step_id: id,
                    extra_details: Some(error.clone()),
                    progress: None,
                },
            )
            .map_err(|e| AppError::OperationUpdate(e.to_string()))?;
        Err(error)
    }

    pub fn fail_if_err<T>(&self, id: &str, res: Result<T, AppError>) -> Result<T, AppError> {
        match res {
            Ok(t) => Ok(t),
            Err(e) => self.fail::<T>(id, e),
        }
    }

    pub fn progress(&self, id: &str, progress: f32) -> Result<(), AppError> {
        self.window
            .emit(
                &format!("operation_{}", self.id),
                OperationUpdate {
                    update_type: "progress",
                    step_id: id,
                    extra_details: None,
                    progress: Some(progress.clamp(0.0, 1.0)),
                },
            )
            .map_err(|e| AppError::OperationUpdate(e.to_string()))
    }
}
