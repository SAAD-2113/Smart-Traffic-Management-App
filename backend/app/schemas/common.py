from typing import Generic, TypeVar

from pydantic import BaseModel, ConfigDict
from pydantic.alias_generators import to_camel

T = TypeVar("T")


class ApiModel(BaseModel):
    """Response models: camelCase JSON, readable from ORM objects."""

    model_config = ConfigDict(alias_generator=to_camel, populate_by_name=True, from_attributes=True)


class ApiInput(BaseModel):
    """Request models: camelCase JSON; unknown fields are rejected.

    Rejecting unknown fields means a client cannot sneak in e.g. {"role": "MANAGER"}.
    """

    model_config = ConfigDict(
        alias_generator=to_camel, populate_by_name=True, extra="forbid", str_strip_whitespace=True
    )


class Page(ApiModel, Generic[T]):
    items: list[T]
    total: int
    limit: int
    offset: int


class MessageOut(ApiModel):
    message: str
