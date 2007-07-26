!
! Copyright (C) 2002-2005 FPMD-CPV groups
! This file is distributed under the terms of the
! GNU General Public License. See the file `License'
! in the root directory of the present distribution,
! or http://www.gnu.org/copyleft/gpl.txt .
!
!  ----------------------------------------------
!  This Module written by Carlo Cavazzoni 
!  Last modified April 2003
!  ----------------------------------------------

#include "f_defs.h"

!=---------------------------------------------------------------------==!
!
!
!     FFT high level Driver 
!     ( Charge density and Wave Functions )
!
!
!=---------------------------------------------------------------------==!
!

MODULE fft_cp

  USE fft_types, ONLY: fft_dlay_descriptor

  IMPLICIT NONE
  SAVE

  INTEGER, PRIVATE :: what_scatter = 1

CONTAINS

!----------------------------------------------------------------------
   SUBROUTINE cfft_cp ( f, nr1, nr2, nr3, nr1x, nr2x, nr3x, sign, dfft )
!----------------------------------------------------------------------
!
!   sign = +-1 : parallel 3d fft for rho and for the potential
!   sign = +-2 : parallel 3d fft for wavefunctions
!
!   sign = + : G-space to R-space, output = \sum_G f(G)exp(+iG*R)
!              fft along z using pencils        (cft_1z)
!              transpose across nodes           (fft_scatter)
!                 and reorder
!              fft along y (using planes) and x (cft_2xy)
!   sign = - : R-space to G-space, output = \int_R f(R)exp(-iG*R)/Omega 
!              fft along x and y(using planes)  (cft_2xy)
!              transpose across nodes           (fft_scatter)
!                 and reorder
!              fft along z using pencils        (cft_1z)
!
!   The array "planes" signals whether a fft is needed along y :
!     planes(i)=0 : column f(i,*,*) empty , don't do fft along y
!     planes(i)=1 : column f(i,*,*) filled, fft along y needed
!   "empty" = no active components are present in f(i,*,*) 
!             after (sign>0) or before (sign<0) the fft on z direction
!
!   Note that if sign=+/-1 (fft on rho and pot.) all fft's are needed
!   and all planes(i) are set to 1
!
!   based on code written by Stefano de Gironcoli for PWSCF
!
      use kinds,      only: DP
      use mp_global,  only: me_image, nproc_image, intra_image_comm
      use fft_scalar, only: cft_1z, cft_2xy
!
      implicit none
      !
      integer, intent(in) :: nr1, nr2, nr3, nr1x, nr2x, nr3x, sign
      type (fft_dlay_descriptor), intent(in) :: dfft
      complex(DP) :: f( : )
      complex(DP), allocatable :: aux( : )

      integer  mc, i, j, ii, proc, k, me
      integer planes(nr1x)
!
! see comments in cfftp for the logic (or lack of it) of the following
!
      if ( nr1  /= dfft%nr1  ) call errore(' cfft ',' wrong dims ', 1)
      if ( nr2  /= dfft%nr2  ) call errore(' cfft ',' wrong dims ', 2)
      if ( nr3  /= dfft%nr3  ) call errore(' cfft ',' wrong dims ', 3)
      if ( nr1x /= dfft%nr1x ) call errore(' cfft ',' wrong dims ', 4)
      if ( nr2x /= dfft%nr2x ) call errore(' cfft ',' wrong dims ', 5)
      if ( nr3x /= dfft%nr3x ) call errore(' cfft ',' wrong dims ', 6)

      me = me_image + 1

      allocate( aux( dfft%nnr ) )

      if ( sign > 0 ) then
         !
         if ( sign /= 2 ) then
            call cft_1z( f, dfft%nsp(me), nr3, nr3x, sign, aux )
            CALL fw_scatter( sign ) ! forwart scatter from stick to planes
            planes = dfft%iplp
         else
            call cft_1z( f, dfft%nsw(me), nr3, nr3x, sign, aux )
            CALL fw_scatter( sign ) ! forwart scatter from stick to planes
            planes = dfft%iplw
         end if
         !
         call cft_2xy( f, dfft%npp( me ), nr1, nr2, nr1x, nr2x, sign, planes )
         !
      else
         !
         if ( sign .ne. -2 ) then
            planes = dfft%iplp
         else
            planes = dfft%iplw
         endif
         !
         call cft_2xy( f, dfft%npp(me), nr1, nr2, nr1x, nr2x, sign, planes)
         !
         if ( sign /= -2 ) then
            call bw_scatter( sign )
            call cft_1z( aux, dfft%nsp( me ), nr3, nr3x, sign, f )
         else
            call bw_scatter( sign )
            call cft_1z( aux, dfft%nsw( me ), nr3, nr3x, sign, f )
         end if
         !
      end if
!
      deallocate( aux )

      RETURN
      !
      !
   CONTAINS
      !
      !
      SUBROUTINE fw_scatter( iopt )
         !
         use fft_base, only: fft_scatter, fft_transpose, fft_itranspose
         !
         INTEGER, INTENT(IN) :: iopt
         INTEGER :: nppx
         !
         !
         IF( iopt == 2 ) THEN
            !
            IF( what_scatter == 1 ) THEN
               call fft_transpose ( aux, nr3x, f, nr1x, nr2x, dfft, me, intra_image_comm, nproc_image, -2)
            ELSE IF( what_scatter == 2 ) THEN
               call fft_itranspose( aux, nr3x, f, nr1x, nr2x, dfft, me, intra_image_comm, nproc_image, -2)
            ELSE 
               if ( nproc_image == 1 ) then
                  nppx = dfft%nr3x
               else
                  nppx = dfft%npp( me )
               end if
               call fft_scatter( aux, nr3x, dfft%nnr, f, dfft%nsw, dfft%npp, iopt )
               f(:) = (0.d0, 0.d0)
               ii = 0
               do proc = 1, nproc_image
                  do i = 1, dfft%nsw( proc )
                     mc = dfft%ismap( i + dfft%iss( proc ) )
                     ii = ii + 1 
                     do j = 1, dfft%npp( me )
                        f( mc + ( j - 1 ) * dfft%nnp ) = aux( j + ( ii - 1 ) * nppx )
                     end do
                  end do
               end do
            END IF
            !
         ELSE IF( iopt == 1 ) THEN
            !
            if ( nproc_image == 1 ) then
               nppx = dfft%nr3x
            else
               nppx = dfft%npp( me )
            end if
            call fft_scatter( aux, nr3x, dfft%nnr, f, dfft%nsp, dfft%npp, iopt )
            f(:) = (0.d0, 0.d0)
            do i = 1, dfft%nst
               mc = dfft%ismap( i )
               do j = 1, dfft%npp( me )
                  f( mc + ( j - 1 ) * dfft%nnp ) = aux( j + ( i - 1 ) * nppx )
               end do
            end do
            !
         END IF
         !
         RETURN 
      END SUBROUTINE fw_scatter
      !
      !  
      !
      SUBROUTINE bw_scatter( iopt )
         !
         use fft_base, only: fft_scatter, fft_transpose, fft_itranspose
         !
         INTEGER, INTENT(IN) :: iopt
         INTEGER :: nppx
         !
         !
         IF( iopt == -2 ) THEN
            !
            IF( what_scatter == 1 ) THEN
               call fft_transpose ( aux, nr3x, f, nr1x, nr2x, dfft, me, intra_image_comm, nproc_image, 2)
            ELSE IF( what_scatter == 2 ) THEN
               call fft_itranspose( aux, nr3x, f, nr1x, nr2x, dfft, me, intra_image_comm, nproc_image, 2)
            ELSE 
               if ( nproc_image == 1 ) then
                  nppx = dfft%nr3x
               else
                  nppx = dfft%npp( me )
               end if
               ii = 0
               do proc = 1, nproc_image
                  do i = 1, dfft%nsw( proc )
                     mc = dfft%ismap( i + dfft%iss( proc ) )
                     ii = ii + 1 
                     do j = 1, dfft%npp( me )
                        aux( j + ( ii - 1 ) * nppx ) = f( mc + ( j - 1 ) * dfft%nnp )
                     end do
                  end do
               end do
               call fft_scatter( aux, nr3x, dfft%nnr, f, dfft%nsw, dfft%npp, iopt )
            END IF
            !
         ELSE IF( iopt == -1 ) THEN
            !
            if ( nproc_image == 1 ) then
               nppx = dfft%nr3x
            else
               nppx = dfft%npp( me )
            end if
            do i = 1, dfft%nst
               mc = dfft%ismap( i )
               do j = 1, dfft%npp( me )
                  aux( j + ( i - 1 ) * nppx ) = f( mc + ( j - 1 ) * dfft%nnp )
               end do
            end do
            call fft_scatter( aux, nr3x, dfft%nnr, f, dfft%nsp, dfft%npp, iopt )
            !
         END IF
         !
         RETURN 
      END SUBROUTINE bw_scatter
      !
      !  
      !
   END SUBROUTINE cfft_cp
   !
   !
   !
   !=======================================================================
   ! ADDED TASK GROUP FFT DRIVERS
   !=======================================================================

   !----------------------------------------------------------------------
   !TASK GROUPS FFT ROUTINE.
   !Added: C. Bekas, Oct. 2005. Adopted from the CPMD code (A. Curioni)
   !----------------------------------------------------------------------

!----------------------------------------------------------------------
    SUBROUTINE tg_cfft_cp ( f, nr1, nr2, nr3, nr1x, nr2x, nr3x, sign, dfft )
!----------------------------------------------------------------------
!
!   sign = +-1 : parallel 3d fft for rho and for the potential
!   sign = +-2 : parallel 3d fft for wavefunctions
!
!   sign = + : G-space to R-space, output = \sum_G f(G)exp(+iG*R)
!              fft along z using pencils        (cft_1)
!              transpose across nodes           (fft_scatter)
!                 and reorder
!              fft along y (using planes) and x (cft_2)
!   sign = - : R-space to G-space, output = \int_R f(R)exp(-iG*R)/Omega
!              fft along x and y(using planes)  (cft_2)
!              transpose across nodes           (fft_scatter)
!                 and reorder
!              fft along z using pencils        (cft_1)
!
!   The array "planes" signals whether a fft is needed along y :
!     planes(i)=0 : column f(i,*,*) empty , don't do fft along y
!     planes(i)=1 : column f(i,*,*) filled, fft along y needed
!   "empty" = no active components are present in f(i,*,*)
!             after (sign>0) or before (sign<0) the fft on z direction
!
!   Note that if sign=+/-1 (fft on rho and pot.) all fft's are needed
!   and all planes(i) are set to 1
!
!   based on code written by Stefano de Gironcoli for PWSCF
!
      USE kinds,      only: DP
      USE mp_global,  only: me_image, nproc_image, ogrp_comm, npgrp, nogrp, &
                            intra_image_comm
      USE fft_base,   only: fft_scatter
      USE fft_scalar, only: cft_1z, cft_2xy
      USE task_groups
      USE parallel_include

      IMPLICIT NONE

      INTEGER, INTENT(IN) :: nr1, nr2, nr3, nr1x, nr2x, nr3x, sign
      TYPE (fft_dlay_descriptor), INTENT(IN) :: dfft

      COMPLEX(DP), INTENT(INOUT) :: f( : )

      integer  mc, i, j, ii, proc, k, me
      integer  group_index, nnz_index, offset, ierr

      !--------------
      !C. Bekas
      !--------------
      INTEGER :: HWMN, IT1, FLAG
      COMPLEX(DP), DIMENSION(:), ALLOCATABLE  :: XF, YF, aux 
      INTEGER, DIMENSION(NOGRP) :: send_cnt, send_displ, recv_cnt, recv_displ
      INTEGER  :: idx

      ALLOCATE( XF ( (NOGRP+1)*strd ) )
      ALLOCATE( YF ( (NOGRP+1)*strd ) )
      ALLOCATE( aux( (NOGRP+1)*strd ) )
 
      !
      ! see comments in cfftp for the logic (or lack of it) of the following
      !
      if ( nr1  /= dfft%nr1  ) call errore(' cfft ',' wrong dims ', 1)
      if ( nr2  /= dfft%nr2  ) call errore(' cfft ',' wrong dims ', 2)
      if ( nr3  /= dfft%nr3  ) call errore(' cfft ',' wrong dims ', 3)
      if ( nr1x /= dfft%nr1x ) call errore(' cfft ',' wrong dims ', 4)
      if ( nr2x /= dfft%nr2x ) call errore(' cfft ',' wrong dims ', 5)
      if ( nr3x /= dfft%nr3x ) call errore(' cfft ',' wrong dims ', 6)

      me = me_image + 1


      if ( sign > 0 ) then

         !  Inverse FFT

         if ( sign /= 2 ) then
            !
            CALL errore( ' tg_cfft ', ' task groups are implemented only for waves ', 1 )
            !
         else
            !
            ! WAVE - FUNCTION FFT calculation
            !

            send_cnt(1)   = nr3x*dfft%nsw( me_image + 1 )
            send_displ(1) = 0
            recv_cnt(1)   = nr3x*dfft%nsw( nolist(1) + 1 )
            recv_displ(1) = 0
            DO idx = 2, nogrp
               send_cnt(idx)   = nr3x * dfft%nsw( me_image + 1 )
               send_displ(idx) = send_displ(idx-1) + strd
               recv_cnt(idx)   = nr3x * dfft%nsw( nolist(idx) + 1 )
               recv_displ(idx) = recv_displ(idx-1) + recv_cnt(idx-1)
            ENDDO

            CALL start_clock( 'ALLTOALL' )

            !
            !  Collect all the sticks of the different states,
            !  in "yf" processors will have all the sticks of the OGRP

#if defined __MPI
            CALL MPI_ALLTOALLV( f, send_cnt, send_displ, MPI_DOUBLE_COMPLEX, yf, recv_cnt, & 
         &                     recv_displ, MPI_DOUBLE_COMPLEX, ogrp_comm, IERR)  
#endif

            CALL stop_clock( 'ALLTOALL' )

            !-------------------------------------------------------------
            !YF Contains all ( ~ NOGRP*dfft%nsw(me) ) Z-sticks
            !-------------------------------------------------------------
            !Do all decoupled FFTs across the Z-sticks
            !-------------------------------------------------------------

            call cft_1z( yf, tmp_nsw(me), nr3, nr3x, sign, aux)

            !-------------------------------------------------------------------------------------
            !Transpose data for the 2-D FFT on the x-y plane
            !-----------------------------------------------
            !NOGRP*dfft%nnr: The length of aux and f
            !nr3x: The length of each Z-stick
            !aux: input - output
            !f: working space
            !sign: type of scatter
            !dfft%nsw(me) holds the number of Z-sticks proc. me has.
            !dfft%npp: number of planes per processor
            !-------------------------------------------------------------------------------------

            call fft_scatter( aux, nr3x, (NOGRP+1)*strd, f, tmp_nsw, tmp_npp, sign, use_tg = .TRUE. )

            f(:) = (0.d0, 0.d0)

            ii=0
            do proc=1,nproc_image
               do i=1,dfft%nsw(proc)
                  mc = dfft%ismap( i + dfft%iss(proc))
                  ii = ii + 1
                  do j=1,tmp_npp(me)
                     f(mc+(j-1)*nr1x*nr2x) = aux(j + (ii-1)*tmp_npp(me))
                  end do
               end do
            end do

            call cft_2xy( f, tmp_npp(me), nr1, nr2, nr1x, nr2x, sign, dfft%iplw )

         end if


      else

         !
         !  FORWARD FFT
         !

         if ( sign /= -2 ) then
            !
            CALL errore( ' tg_cfft ', ' task groups are implemented only for waves ', 1 )
            !
         else
            !
            !  WAVE - FUNCTION FFT calculation
            !
            call cft_2xy( f, tmp_npp(me), nr1, nr2, nr1x, nr2x, sign, dfft%iplw )
            ii = 0
            do proc=1,nproc_image
               do i=1,dfft%nsw(proc)
                  mc = dfft%ismap( i + dfft%iss(proc) )
                  ii = ii + 1
                  do j=1,tmp_npp(me)
                     aux(j + (ii-1)*tmp_npp(me)) = f(mc+(j-1)*nr1x*nr2x)
                  end do
               end do
            end do

            call fft_scatter( aux, nr3x, (NOGRP+1)*strd, f, tmp_nsw, tmp_npp, sign, use_tg = .TRUE. )
            call cft_1z(aux,tmp_nsw(me),nr3,nr3x,sign,f)

         end if

      end if
!

      DEALLOCATE(XF)
      DEALLOCATE(YF)
      DEALLOCATE(aux)

      RETURN
   END SUBROUTINE tg_cfft_cp
   !
   !
   !
END MODULE fft_cp
