from fastapi import APIRouter, BackgroundTasks, Depends, Request, status
from sqlalchemy.ext.asyncio import AsyncSession

from app.api.deps import AuthContext, client_ip, get_auth_context
from app.core.rate_limit import limiter
from app.db.session import get_db
from app.models.enums import UserRole
from app.models.user import User
from app.schemas.auth import (
    ChangePasswordRequest,
    ForgotPasswordRequest,
    LoginRequest,
    LoginResponse,
    RefreshRequest,
    RegisterRequest,
    ResetPasswordRequest,
    TokenPair,
)
from app.schemas.common import MessageOut
from app.schemas.user import UserOut
from app.services import auth_service

router = APIRouter(prefix="/auth", tags=["auth"])


@router.post("/register", response_model=UserOut, status_code=status.HTTP_201_CREATED)
@limiter.limit("3/hour")
async def register(request: Request, body: RegisterRequest, db: AsyncSession = Depends(get_db)) -> User:
    """Self-registration always creates an END_USER. Manager accounts are created by an admin."""
    return await auth_service.create_user(
        db,
        email=body.email,
        password=body.password,
        full_name=body.full_name,
        phone=body.phone,
        role=UserRole.END_USER,
    )


@router.post("/login", response_model=LoginResponse)
@limiter.limit("5/minute")
async def login(request: Request, body: LoginRequest, db: AsyncSession = Depends(get_db)) -> LoginResponse:
    user, tokens = await auth_service.login(
        db,
        email=body.email,
        password=body.password,
        installation_id=body.installation_id,
        ip=client_ip(request),
    )
    return LoginResponse(
        access_token=tokens.access_token,
        access_expires_in=tokens.access_expires_in,
        refresh_token=tokens.refresh_token,
        refresh_expires_in=tokens.refresh_expires_in,
        user=UserOut.model_validate(user),
    )


@router.post("/refresh", response_model=TokenPair)
@limiter.limit("30/minute")
async def refresh(request: Request, body: RefreshRequest, db: AsyncSession = Depends(get_db)) -> TokenPair:
    tokens = await auth_service.refresh(db, body.refresh_token)
    return TokenPair(
        access_token=tokens.access_token,
        access_expires_in=tokens.access_expires_in,
        refresh_token=tokens.refresh_token,
        refresh_expires_in=tokens.refresh_expires_in,
    )


@router.post("/logout", status_code=status.HTTP_204_NO_CONTENT)
async def logout(body: RefreshRequest, db: AsyncSession = Depends(get_db)) -> None:
    await auth_service.logout(db, body.refresh_token)


@router.post("/password/forgot", response_model=MessageOut, status_code=status.HTTP_202_ACCEPTED)
@limiter.limit("5/hour")
async def forgot_password(
    request: Request,
    body: ForgotPasswordRequest,
    background: BackgroundTasks,
    db: AsyncSession = Depends(get_db),
) -> MessageOut:
    mail = await auth_service.request_password_reset(db, body.email)
    if mail is not None:
        background.add_task(auth_service.send_password_reset_email, mail)
    # Same response whether or not the account exists.
    return MessageOut(message="If an account exists for this email, a reset link has been sent.")


@router.post("/password/reset", status_code=status.HTTP_204_NO_CONTENT)
@limiter.limit("10/hour")
async def reset_password(
    request: Request, body: ResetPasswordRequest, db: AsyncSession = Depends(get_db)
) -> None:
    await auth_service.reset_password(db, body.token, body.new_password)


@router.post("/password/change", status_code=status.HTTP_204_NO_CONTENT)
async def change_password(
    body: ChangePasswordRequest,
    ctx: AuthContext = Depends(get_auth_context),
    db: AsyncSession = Depends(get_db),
) -> None:
    await auth_service.change_password(
        db,
        ctx.user,
        session_id=ctx.session_id,
        current_password=body.current_password,
        new_password=body.new_password,
    )
