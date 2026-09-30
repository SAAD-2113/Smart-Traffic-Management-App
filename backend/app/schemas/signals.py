import uuid
from datetime import datetime

from pydantic import AwareDatetime, Field

from app.models.enums import ActuatorType, ControllerType, LightState, SignalMode
from app.schemas.common import ApiInput, ApiModel
from app.schemas.traffic import SignalDecisionOut, SignalStateOut


class PhaseIn(ApiInput):
    name: str = Field(min_length=1, max_length=64)
    approaches: list[str] = Field(default_factory=list, max_length=8)
    min_green_s: float = Field(ge=1, le=300)
    max_green_s: float = Field(ge=1, le=300)
    fixed_green_s: float = Field(ge=1, le=300)
    yellow_s: float = Field(ge=0, le=10)
    all_red_s: float = Field(ge=0, le=10)


class SignalPlanIn(ApiInput):
    phases: list[PhaseIn] = Field(min_length=1, max_length=8)
    min_cycle_s: float = Field(default=40, ge=10, le=600)
    max_cycle_s: float = Field(default=120, ge=10, le=600)


class PhaseOut(ApiModel):
    name: str
    approaches: list[str]
    min_green_s: float
    max_green_s: float
    fixed_green_s: float
    yellow_s: float
    all_red_s: float


class SignalPlanOut(ApiModel):
    intersection_id: uuid.UUID
    intersection_code: str
    is_default: bool
    phases: list[PhaseOut]
    min_cycle_s: float
    max_cycle_s: float
    fixed_cycle_s: float
    lost_time_s: float
    updated_at: datetime | None
    approach_bearings: dict[str, float] = Field(
        default_factory=dict,
        description="Direction of travel (degrees) of each approach, so an actuator can map phases to its lanes.",
    )


class SignalOverviewItem(ApiModel):
    intersection_id: uuid.UUID
    code: str
    name: str
    controller_type: ControllerType
    actuator: ActuatorType
    connected: bool
    plan: SignalPlanOut
    decision: SignalDecisionOut | None
    state: SignalStateOut | None


class SignalStateReport(ApiInput):
    intersection_code: str = Field(min_length=1, max_length=16)
    phase_name: str = Field(min_length=1, max_length=64)
    state: LightState
    mode: SignalMode
    remaining_s: float | None = Field(default=None, ge=0, le=600)
    decision_id: uuid.UUID | None = None
    reported_at: AwareDatetime | None = None


class SignalStateBatch(ApiInput):
    states: list[SignalStateReport] = Field(min_length=1, max_length=50)


class ControllerDecisionsOut(ApiModel):
    server_time: datetime
    decisions: list[SignalDecisionOut]
    plans: list[SignalPlanOut]
