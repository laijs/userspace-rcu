/*
 * mem.spin: Promela code to validate memory barriers with OOO memory
 * and out-of-order instruction scheduling.
 *
 * This program is free software; you can redistribute it and/or modify
 * it under the terms of the GNU General Public License as published by
 * the Free Software Foundation; either version 2 of the License, or
 * (at your option) any later version.
 *
 * This program is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 * GNU General Public License for more details.
 *
 * You should have received a copy of the GNU General Public License
 * along with this program; if not, write to the Free Software
 * Foundation, Inc., 59 Temple Place - Suite 330, Boston, MA 02111-1307, USA.
 *
 * Copyright (c) 2009 Mathieu Desnoyers
 */

/* Promela validation variables. */

/* specific defines "included" here */
/* DEFINES file "included" here */

#define NR_READERS 1
#define NR_WRITERS 1

#define NR_PROCS 2

#define get_pid()	(_pid)

#define get_readerid()	(get_pid())

/*
 * Produced process control and data flow. Updated after each instruction to
 * show which variables are ready. Using one-hot bit encoding per variable to
 * save state space. Used as triggers to execute the instructions having those
 * variables as input. Leaving bits active to inhibit instruction execution.
 * Scheme used to make instruction disabling and automatic dependency fall-back
 * automatic.
 */

#define CONSUME_TOKENS(state, bits, notbits)			\
	((!(state & (notbits))) && (state & (bits)) == (bits))

#define PRODUCE_TOKENS(state, bits)				\
	state = state | (bits);

#define CLEAR_TOKENS(state, bits)				\
	state = state & ~(bits)

/*
 * Types of dependency :
 *
 * Data dependency
 *
 * - True dependency, Read-after-Write (RAW)
 *
 * This type of dependency happens when a statement depends on the result of a
 * previous statement. This applies to any statement which needs to read a
 * variable written by a preceding statement.
 *
 * - False dependency, Write-after-Read (WAR)
 *
 * Typically, variable renaming can ensure that this dependency goes away.
 * However, if the statements must read and then write from/to the same variable
 * in the OOO memory model, renaming may be impossible, and therefore this
 * causes a WAR dependency.
 *
 * - Output dependency, Write-after-Write (WAW)
 *
 * Two writes to the same variable in subsequent statements. Variable renaming
 * can ensure this is not needed, but can be required when writing multiple
 * times to the same OOO mem model variable.
 *
 * Control dependency
 *
 * Execution of a given instruction depends on a previous instruction evaluating
 * in a way that allows its execution. E.g. : branches.
 *
 * Useful considerations for joining dependencies after branch
 *
 * - Pre-dominance
 *
 * "We say box i dominates box j if every path (leading from input to output
 * through the diagram) which passes through box j must also pass through box
 * i. Thus box i dominates box j if box j is subordinate to box i in the
 * program."
 *
 * http://www.hipersoft.rice.edu/grads/publications/dom14.pdf
 * Other classic algorithm to calculate dominance : Lengauer-Tarjan (in gcc)
 *
 * - Post-dominance
 *
 * Just as pre-dominance, but with arcs of the data flow inverted, and input vs
 * output exchanged. Therefore, i post-dominating j ensures that every path
 * passing by j will pass by i before reaching the output.
 *
 * Other considerations
 *
 * Note about "volatile" keyword dependency : The compiler will order volatile
 * accesses so they appear in the right order on a given CPU. They can be
 * reordered by the CPU instruction scheduling. This therefore cannot be
 * considered as a depencency.
 *
 * References :
 *
 * Cooper, Keith D.; & Torczon, Linda. (2005). Engineering a Compiler. Morgan
 * Kaufmann. ISBN 1-55860-698-X. 
 * Kennedy, Ken; & Allen, Randy. (2001). Optimizing Compilers for Modern
 * Architectures: A Dependence-based Approach. Morgan Kaufmann. ISBN
 * 1-55860-286-0. 
 * Muchnick, Steven S. (1997). Advanced Compiler Design and Implementation.
 * Morgan Kaufmann. ISBN 1-55860-320-4.
 */

/*
 * Note about loops and nested calls
 *
 * To keep this model simple, loops expressed in the framework will behave as if
 * there was a core synchronizing instruction between loops. To see the effect
 * of loop unrolling, manually unrolling loops is required. Note that if loops
 * end or start with a core synchronizing instruction, the model is appropriate.
 * Nested calls are not supported.
 */

/*
 * Only Alpha has out-of-order cache bank loads. Other architectures (intel,
 * powerpc, arm) ensure that dependent reads won't be reordered. c.f.
 * http://www.linuxjournal.com/article/8212)
#ifdef ARCH_ALPHA
#define HAVE_OOO_CACHE_READ
#endif

/*
 * Each process have its own data in cache. Caches are randomly updated.
 * smp_wmb and smp_rmb forces cache updates (write and read), smp_mb forces
 * both.
 */

typedef per_proc_byte {
	byte val[NR_PROCS];
};

typedef per_proc_bit {
	bit val[NR_PROCS];
};

/* Bitfield has a maximum of 8 procs */
typedef per_proc_bitfield {
	byte bitfield;
};

#define DECLARE_CACHED_VAR(type, x)	\
	type mem_##x;			\
	per_proc_##type cached_##x;	\
	per_proc_bitfield cache_dirty_##x;

#define INIT_CACHED_VAR(x, v, j)	\
	mem_##x = v;			\
	cache_dirty_##x.bitfield = 0;	\
	j = 0;				\
	do				\
	:: j < NR_PROCS ->		\
		cached_##x.val[j] = v;	\
		j++			\
	:: j >= NR_PROCS -> break	\
	od;

#define IS_CACHE_DIRTY(x, id)	(cache_dirty_##x.bitfield & (1 << id))

#define READ_CACHED_VAR(x)	(cached_##x.val[get_pid()])

#define WRITE_CACHED_VAR(x, v)				\
	atomic {					\
		cached_##x.val[get_pid()] = v;		\
		cache_dirty_##x.bitfield =		\
			cache_dirty_##x.bitfield | (1 << get_pid());	\
	}

#define CACHE_WRITE_TO_MEM(x, id)			\
	if						\
	:: IS_CACHE_DIRTY(x, id) ->			\
		mem_##x = cached_##x.val[id];		\
		cache_dirty_##x.bitfield =		\
			cache_dirty_##x.bitfield & (~(1 << id));	\
	:: else ->					\
		skip					\
	fi;

#define CACHE_READ_FROM_MEM(x, id)	\
	if				\
	:: !IS_CACHE_DIRTY(x, id) ->	\
		cached_##x.val[id] = mem_##x;\
	:: else ->			\
		skip			\
	fi;

/*
 * May update other caches if cache is dirty, or not.
 */
#define RANDOM_CACHE_WRITE_TO_MEM(x, id)\
	if				\
	:: 1 -> CACHE_WRITE_TO_MEM(x, id);	\
	:: 1 -> skip			\
	fi;

#define RANDOM_CACHE_READ_FROM_MEM(x, id)\
	if				\
	:: 1 -> CACHE_READ_FROM_MEM(x, id);	\
	:: 1 -> skip			\
	fi;

/* Must consume all prior read tokens. All subsequent reads depend on it. */
inline smp_rmb(i)
{
	atomic {
		CACHE_READ_FROM_MEM(urcu_gp_ctr, get_pid());
		i = 0;
		do
		:: i < NR_READERS ->
			CACHE_READ_FROM_MEM(urcu_active_readers[i], get_pid());
			i++
		:: i >= NR_READERS -> break
		od;
		CACHE_READ_FROM_MEM(rcu_ptr, get_pid());
		i = 0;
		do
		:: i < SLAB_SIZE ->
			CACHE_READ_FROM_MEM(rcu_data[i], get_pid());
			i++
		:: i >= SLAB_SIZE -> break
		od;
	}
}

/* Must consume all prior write tokens. All subsequent writes depend on it. */
inline smp_wmb(i)
{
	atomic {
		CACHE_WRITE_TO_MEM(urcu_gp_ctr, get_pid());
		i = 0;
		do
		:: i < NR_READERS ->
			CACHE_WRITE_TO_MEM(urcu_active_readers[i], get_pid());
			i++
		:: i >= NR_READERS -> break
		od;
		CACHE_WRITE_TO_MEM(rcu_ptr, get_pid());
		i = 0;
		do
		:: i < SLAB_SIZE ->
			CACHE_WRITE_TO_MEM(rcu_data[i], get_pid());
			i++
		:: i >= SLAB_SIZE -> break
		od;
	}
}

/* Synchronization point. Must consume all prior read and write tokens. All
 * subsequent reads and writes depend on it. */
inline smp_mb(i)
{
	atomic {
		smp_wmb(i);
		smp_rmb(i);
	}
}

#ifdef REMOTE_BARRIERS

bit reader_barrier[NR_READERS];

/*
 * We cannot leave the barriers dependencies in place in REMOTE_BARRIERS mode
 * because they would add unexisting core synchronization and would therefore
 * create an incomplete model.
 * Therefore, we model the read-side memory barriers by completely disabling the
 * memory barriers and their dependencies from the read-side. One at a time
 * (different verification runs), we make a different instruction listen for
 * signals.
 */

#define smp_mb_reader(i, j)

/*
 * Service 0, 1 or many barrier requests.
 */
inline smp_mb_recv(i, j)
{
	do
	:: (reader_barrier[get_readerid()] == 1) ->
		/*
		 * We choose to ignore cycles caused by writer busy-looping,
		 * waiting for the reader, sending barrier requests, and the
		 * reader always services them without continuing execution.
		 */
progress_ignoring_mb1:
		smp_mb(i);
		reader_barrier[get_readerid()] = 0;
	:: 1 ->
		/*
		 * We choose to ignore writer's non-progress caused by the
		 * reader ignoring the writer's mb() requests.
		 */
progress_ignoring_mb2:
		break;
	od;
}

#define PROGRESS_LABEL(progressid)	progress_writer_progid_##progressid:

#define smp_mb_send(i, j, progressid)						\
{										\
	smp_mb(i);								\
	i = 0;									\
	do									\
	:: i < NR_READERS ->							\
		reader_barrier[i] = 1;						\
		/*								\
		 * Busy-looping waiting for reader barrier handling is of little\
		 * interest, given the reader has the ability to totally ignore	\
		 * barrier requests.						\
		 */								\
		do								\
		:: (reader_barrier[i] == 1) ->					\
PROGRESS_LABEL(progressid)							\
			skip;							\
		:: (reader_barrier[i] == 0) -> break;				\
		od;								\
		i++;								\
	:: i >= NR_READERS ->							\
		break								\
	od;									\
	smp_mb(i);								\
}

#else

#define smp_mb_send(i, j, progressid)	smp_mb(i)
#define smp_mb_reader	smp_mb(i)
#define smp_mb_recv(i, j)

#endif

/* Keep in sync manually with smp_rmb, smp_wmb, ooo_mem and init() */
DECLARE_CACHED_VAR(byte, urcu_gp_ctr);
/* Note ! currently only one reader */
DECLARE_CACHED_VAR(byte, urcu_active_readers[NR_READERS]);
/* RCU data */
DECLARE_CACHED_VAR(bit, rcu_data[SLAB_SIZE]);

/* RCU pointer */
#if (SLAB_SIZE == 2)
DECLARE_CACHED_VAR(bit, rcu_ptr);
bit ptr_read_first[NR_READERS];
bit ptr_read_second[NR_READERS];
#else
DECLARE_CACHED_VAR(byte, rcu_ptr);
byte ptr_read_first[NR_READERS];
byte ptr_read_second[NR_READERS];
#endif

bit data_read_first[NR_READERS];
bit data_read_second[NR_READERS];

bit init_done = 0;

inline wait_init_done()
{
	do
	:: init_done == 0 -> skip;
	:: else -> break;
	od;
}

inline ooo_mem(i)
{
	atomic {
		RANDOM_CACHE_WRITE_TO_MEM(urcu_gp_ctr, get_pid());
		i = 0;
		do
		:: i < NR_READERS ->
			RANDOM_CACHE_WRITE_TO_MEM(urcu_active_readers[i],
				get_pid());
			i++
		:: i >= NR_READERS -> break
		od;
		RANDOM_CACHE_WRITE_TO_MEM(rcu_ptr, get_pid());
		i = 0;
		do
		:: i < SLAB_SIZE ->
			RANDOM_CACHE_WRITE_TO_MEM(rcu_data[i], get_pid());
			i++
		:: i >= SLAB_SIZE -> break
		od;
#ifdef HAVE_OOO_CACHE_READ
		RANDOM_CACHE_READ_FROM_MEM(urcu_gp_ctr, get_pid());
		i = 0;
		do
		:: i < NR_READERS ->
			RANDOM_CACHE_READ_FROM_MEM(urcu_active_readers[i],
				get_pid());
			i++
		:: i >= NR_READERS -> break
		od;
		RANDOM_CACHE_READ_FROM_MEM(rcu_ptr, get_pid());
		i = 0;
		do
		:: i < SLAB_SIZE ->
			RANDOM_CACHE_READ_FROM_MEM(rcu_data[i], get_pid());
			i++
		:: i >= SLAB_SIZE -> break
		od;
#else
		smp_rmb(i);
#endif /* HAVE_OOO_CACHE_READ */
	}
}

/*
 * Bit encoding, urcu_reader :
 */

int _proc_urcu_reader;
#define proc_urcu_reader	_proc_urcu_reader

/* Body of PROCEDURE_READ_LOCK */
#define READ_PROD_A_READ		(1 << 0)
#define READ_PROD_B_IF_TRUE		(1 << 1)
#define READ_PROD_B_IF_FALSE		(1 << 2)
#define READ_PROD_C_IF_TRUE_READ	(1 << 3)

#define PROCEDURE_READ_LOCK(base, consumetoken, producetoken)				\
	:: CONSUME_TOKENS(proc_urcu_reader, consumetoken, READ_PROD_A_READ << base) ->	\
		ooo_mem(i);								\
		tmp = READ_CACHED_VAR(urcu_active_readers[get_readerid()]);		\
		PRODUCE_TOKENS(proc_urcu_reader, READ_PROD_A_READ << base);		\
	:: CONSUME_TOKENS(proc_urcu_reader,						\
			  READ_PROD_A_READ << base,		/* RAW, pre-dominant */	\
			  (READ_PROD_B_IF_TRUE | READ_PROD_B_IF_FALSE) << base) ->	\
		if									\
		:: (!(tmp & RCU_GP_CTR_NEST_MASK)) ->					\
			PRODUCE_TOKENS(proc_urcu_reader, READ_PROD_B_IF_TRUE << base);	\
		:: else ->								\
			PRODUCE_TOKENS(proc_urcu_reader, READ_PROD_B_IF_FALSE << base);	\
		fi;									\
	/* IF TRUE */									\
	:: CONSUME_TOKENS(proc_urcu_reader, READ_PROD_B_IF_TRUE << base,		\
			  READ_PROD_C_IF_TRUE_READ << base) ->				\
		ooo_mem(i);								\
		tmp2 = READ_CACHED_VAR(urcu_gp_ctr);					\
		PRODUCE_TOKENS(proc_urcu_reader, READ_PROD_C_IF_TRUE_READ << base);	\
	:: CONSUME_TOKENS(proc_urcu_reader,						\
			  (READ_PROD_C_IF_TRUE_READ	/* pre-dominant */		\
			  | READ_PROD_A_READ) << base,		/* WAR */		\
			  producetoken) ->						\
		ooo_mem(i);								\
		WRITE_CACHED_VAR(urcu_active_readers[get_readerid()], tmp2);		\
		PRODUCE_TOKENS(proc_urcu_reader, producetoken);				\
							/* IF_MERGE implies		\
							 * post-dominance */		\
	/* ELSE */									\
	:: CONSUME_TOKENS(proc_urcu_reader,						\
			  (READ_PROD_B_IF_FALSE		/* pre-dominant */		\
			  | READ_PROD_A_READ) << base,		/* WAR */		\
			  producetoken) ->						\
		ooo_mem(i);								\
		WRITE_CACHED_VAR(urcu_active_readers[get_readerid()],			\
				 tmp + 1);						\
		PRODUCE_TOKENS(proc_urcu_reader, producetoken);				\
							/* IF_MERGE implies		\
							 * post-dominance */		\
	/* ENDIF */									\
	skip

/* Body of PROCEDURE_READ_LOCK */
#define READ_PROC_READ_UNLOCK		(1 << 0)

#define PROCEDURE_READ_UNLOCK(base, consumetoken, producetoken)				\
	:: CONSUME_TOKENS(proc_urcu_reader,						\
			  consumetoken,							\
			  READ_PROC_READ_UNLOCK << base) ->				\
		ooo_mem(i);								\
		tmp2 = READ_CACHED_VAR(urcu_active_readers[get_readerid()]);		\
		PRODUCE_TOKENS(proc_urcu_reader, READ_PROC_READ_UNLOCK << base);	\
	:: CONSUME_TOKENS(proc_urcu_reader,						\
			  consumetoken							\
			  | (READ_PROC_READ_UNLOCK << base),	/* WAR */		\
			  producetoken) ->						\
		ooo_mem(i);								\
		WRITE_CACHED_VAR(urcu_active_readers[get_readerid()], tmp2 - 1);	\
		PRODUCE_TOKENS(proc_urcu_reader, producetoken);				\
	skip


#define READ_PROD_NONE			(1 << 0)

/* PROCEDURE_READ_LOCK base = << 1 : 1 to 5 */
#define READ_LOCK_BASE			1
#define READ_LOCK_OUT			(1 << 5)

#define READ_PROC_FIRST_MB		(1 << 6)

/* PROCEDURE_READ_LOCK (NESTED) base : << 7 : 7 to 11 */
#define READ_LOCK_NESTED_BASE		7
#define READ_LOCK_NESTED_OUT		(1 << 11)

#define READ_PROC_READ_GEN		(1 << 12)
#define READ_PROC_ACCESS_GEN		(1 << 13)

/* PROCEDURE_READ_UNLOCK (NESTED) base = << 14 : 14 to 15 */
#define READ_UNLOCK_NESTED_BASE		14
#define READ_UNLOCK_NESTED_OUT		(1 << 15)

#define READ_PROC_SECOND_MB		(1 << 16)

/* PROCEDURE_READ_UNLOCK base = << 17 : 17 to 18 */
#define READ_UNLOCK_BASE		17
#define READ_UNLOCK_OUT			(1 << 18)

/* PROCEDURE_READ_LOCK_UNROLL base = << 19 : 19 to 23 */
#define READ_LOCK_UNROLL_BASE		19
#define READ_LOCK_OUT_UNROLL		(1 << 23)

#define READ_PROC_THIRD_MB		(1 << 24)

#define READ_PROC_READ_GEN_UNROLL	(1 << 25)
#define READ_PROC_ACCESS_GEN_UNROLL	(1 << 26)

#define READ_PROC_FOURTH_MB		(1 << 27)

/* PROCEDURE_READ_UNLOCK_UNROLL base = << 28 : 28 to 29 */
#define READ_UNLOCK_UNROLL_BASE		28
#define READ_UNLOCK_OUT_UNROLL		(1 << 29)


/* Should not include branches */
#define READ_PROC_ALL_TOKENS		(READ_PROD_NONE			\
					| READ_LOCK_OUT			\
					| READ_PROC_FIRST_MB		\
					| READ_LOCK_NESTED_OUT		\
					| READ_PROC_READ_GEN		\
					| READ_PROC_ACCESS_GEN		\
					| READ_UNLOCK_NESTED_OUT	\
					| READ_PROC_SECOND_MB		\
					| READ_UNLOCK_OUT		\
					| READ_LOCK_OUT_UNROLL		\
					| READ_PROC_THIRD_MB		\
					| READ_PROC_READ_GEN_UNROLL	\
					| READ_PROC_ACCESS_GEN_UNROLL	\
					| READ_PROC_FOURTH_MB		\
					| READ_UNLOCK_OUT_UNROLL)

/* Must clear all tokens, including branches */
#define READ_PROC_ALL_TOKENS_CLEAR	((1 << 30) - 1)

inline urcu_one_read(i, j, nest_i, tmp, tmp2)
{
	PRODUCE_TOKENS(proc_urcu_reader, READ_PROD_NONE);

#ifdef NO_MB
	PRODUCE_TOKENS(proc_urcu_reader, READ_PROC_FIRST_MB);
	PRODUCE_TOKENS(proc_urcu_reader, READ_PROC_SECOND_MB);
	PRODUCE_TOKENS(proc_urcu_reader, READ_PROC_THIRD_MB);
	PRODUCE_TOKENS(proc_urcu_reader, READ_PROC_FOURTH_MB);
#endif

#ifdef REMOTE_BARRIERS
	PRODUCE_TOKENS(proc_urcu_reader, READ_PROC_FIRST_MB);
	PRODUCE_TOKENS(proc_urcu_reader, READ_PROC_SECOND_MB);
	PRODUCE_TOKENS(proc_urcu_reader, READ_PROC_THIRD_MB);
	PRODUCE_TOKENS(proc_urcu_reader, READ_PROC_FOURTH_MB);
#endif

	do
	:: 1 ->

#ifdef REMOTE_BARRIERS
		/*
		 * Signal-based memory barrier will only execute when the
		 * execution order appears in program order.
		 */
		if
		:: 1 ->
			atomic {
				if
				:: CONSUME_TOKENS(proc_urcu_reader, READ_PROD_NONE,
						READ_LOCK_OUT | READ_LOCK_NESTED_OUT
						| READ_PROC_READ_GEN | READ_PROC_ACCESS_GEN | READ_UNLOCK_NESTED_OUT
						| READ_UNLOCK_OUT
						| READ_LOCK_OUT_UNROLL
						| READ_PROC_READ_GEN_UNROLL | READ_PROC_ACCESS_GEN_UNROLL | READ_UNLOCK_OUT_UNROLL)
					|| CONSUME_TOKENS(proc_urcu_reader, READ_PROD_NONE | READ_LOCK_OUT,
						READ_LOCK_NESTED_OUT
						| READ_PROC_READ_GEN | READ_PROC_ACCESS_GEN | READ_UNLOCK_NESTED_OUT
						| READ_UNLOCK_OUT
						| READ_LOCK_OUT_UNROLL
						| READ_PROC_READ_GEN_UNROLL | READ_PROC_ACCESS_GEN_UNROLL | READ_UNLOCK_OUT_UNROLL)
					|| CONSUME_TOKENS(proc_urcu_reader, READ_PROD_NONE | READ_LOCK_OUT | READ_LOCK_NESTED_OUT,
						READ_PROC_READ_GEN | READ_PROC_ACCESS_GEN | READ_UNLOCK_NESTED_OUT
						| READ_UNLOCK_OUT
						| READ_LOCK_OUT_UNROLL
						| READ_PROC_READ_GEN_UNROLL | READ_PROC_ACCESS_GEN_UNROLL | READ_UNLOCK_OUT_UNROLL)
					|| CONSUME_TOKENS(proc_urcu_reader, READ_PROD_NONE | READ_LOCK_OUT
						| READ_LOCK_NESTED_OUT | READ_PROC_READ_GEN,
						READ_PROC_ACCESS_GEN | READ_UNLOCK_NESTED_OUT
						| READ_UNLOCK_OUT
						| READ_LOCK_OUT_UNROLL
						| READ_PROC_READ_GEN_UNROLL | READ_PROC_ACCESS_GEN_UNROLL | READ_UNLOCK_OUT_UNROLL)
					|| CONSUME_TOKENS(proc_urcu_reader, READ_PROD_NONE | READ_LOCK_OUT
						| READ_LOCK_NESTED_OUT | READ_PROC_READ_GEN | READ_PROC_ACCESS_GEN,
						READ_UNLOCK_NESTED_OUT
						| READ_UNLOCK_OUT
						| READ_LOCK_OUT_UNROLL
						| READ_PROC_READ_GEN_UNROLL | READ_PROC_ACCESS_GEN_UNROLL | READ_UNLOCK_OUT_UNROLL)
					|| CONSUME_TOKENS(proc_urcu_reader, READ_PROD_NONE | READ_LOCK_OUT
						| READ_LOCK_NESTED_OUT | READ_PROC_READ_GEN
						| READ_PROC_ACCESS_GEN | READ_UNLOCK_NESTED_OUT,
						READ_UNLOCK_OUT
						| READ_LOCK_OUT_UNROLL
						| READ_PROC_READ_GEN_UNROLL | READ_PROC_ACCESS_GEN_UNROLL | READ_UNLOCK_OUT_UNROLL)
					|| CONSUME_TOKENS(proc_urcu_reader, READ_PROD_NONE | READ_LOCK_OUT
						| READ_LOCK_NESTED_OUT | READ_PROC_READ_GEN
						| READ_PROC_ACCESS_GEN | READ_UNLOCK_NESTED_OUT
						| READ_UNLOCK_OUT,
						READ_LOCK_OUT_UNROLL
						| READ_PROC_READ_GEN_UNROLL | READ_PROC_ACCESS_GEN_UNROLL | READ_UNLOCK_OUT_UNROLL)
					|| CONSUME_TOKENS(proc_urcu_reader, READ_PROD_NONE | READ_LOCK_OUT
						| READ_LOCK_NESTED_OUT | READ_PROC_READ_GEN
						| READ_PROC_ACCESS_GEN | READ_UNLOCK_NESTED_OUT
						| READ_UNLOCK_OUT | READ_LOCK_OUT_UNROLL,
						READ_PROC_READ_GEN_UNROLL | READ_PROC_ACCESS_GEN_UNROLL | READ_UNLOCK_OUT_UNROLL)
					|| CONSUME_TOKENS(proc_urcu_reader, READ_PROD_NONE | READ_LOCK_OUT
						| READ_LOCK_NESTED_OUT | READ_PROC_READ_GEN
						| READ_PROC_ACCESS_GEN | READ_UNLOCK_NESTED_OUT
						| READ_UNLOCK_OUT | READ_LOCK_OUT_UNROLL
						| READ_PROC_READ_GEN_UNROLL,
						READ_PROC_ACCESS_GEN_UNROLL | READ_UNLOCK_OUT_UNROLL)
					|| CONSUME_TOKENS(proc_urcu_reader, READ_PROD_NONE | READ_LOCK_OUT
						| READ_LOCK_NESTED_OUT | READ_PROC_READ_GEN
						| READ_PROC_ACCESS_GEN | READ_UNLOCK_NESTED_OUT
						| READ_UNLOCK_OUT | READ_LOCK_OUT_UNROLL
						| READ_PROC_READ_GEN_UNROLL | READ_PROC_ACCESS_GEN_UNROLL,
						READ_UNLOCK_OUT_UNROLL)
					|| CONSUME_TOKENS(proc_urcu_reader, READ_PROD_NONE | READ_LOCK_OUT
						| READ_LOCK_NESTED_OUT | READ_PROC_READ_GEN | READ_PROC_ACCESS_GEN | READ_UNLOCK_NESTED_OUT
						| READ_UNLOCK_OUT | READ_LOCK_OUT_UNROLL
						| READ_PROC_READ_GEN_UNROLL | READ_PROC_ACCESS_GEN_UNROLL | READ_UNLOCK_OUT_UNROLL,
						0) ->
					goto non_atomic3;
non_atomic3_end:
					skip;
				fi;
			}
		fi;

		goto non_atomic3_skip;
non_atomic3:
		smp_mb_recv(i, j);
		goto non_atomic3_end;
non_atomic3_skip:

#endif /* REMOTE_BARRIERS */

		atomic {
			if
			PROCEDURE_READ_LOCK(READ_LOCK_BASE, READ_PROD_NONE, READ_LOCK_OUT);

			:: CONSUME_TOKENS(proc_urcu_reader,
					  READ_LOCK_OUT,		/* post-dominant */
					  READ_PROC_FIRST_MB) ->
				smp_mb_reader(i, j);
				PRODUCE_TOKENS(proc_urcu_reader, READ_PROC_FIRST_MB);

			PROCEDURE_READ_LOCK(READ_LOCK_NESTED_BASE, READ_PROC_FIRST_MB | READ_LOCK_OUT,
					    READ_LOCK_NESTED_OUT);

			:: CONSUME_TOKENS(proc_urcu_reader,
					  READ_PROC_FIRST_MB,		/* mb() orders reads */
					  READ_PROC_READ_GEN) ->
				ooo_mem(i);
				ptr_read_first[get_readerid()] = READ_CACHED_VAR(rcu_ptr);
				PRODUCE_TOKENS(proc_urcu_reader, READ_PROC_READ_GEN);

			:: CONSUME_TOKENS(proc_urcu_reader,
					  READ_PROC_FIRST_MB		/* mb() orders reads */
					  | READ_PROC_READ_GEN,
					  READ_PROC_ACCESS_GEN) ->
				/* smp_read_barrier_depends */
				goto rmb1;
rmb1_end:
				data_read_first[get_readerid()] =
					READ_CACHED_VAR(rcu_data[ptr_read_first[get_readerid()]]);
				PRODUCE_TOKENS(proc_urcu_reader, READ_PROC_ACCESS_GEN);


			/* Note : we remove the nested memory barrier from the read unlock
			 * model, given it is not usually needed. The implementation has the barrier
			 * because the performance impact added by a branch in the common case does not
			 * justify it.
			 */

			PROCEDURE_READ_UNLOCK(READ_UNLOCK_NESTED_BASE,
					      READ_PROC_FIRST_MB
					      | READ_LOCK_OUT
					      | READ_LOCK_NESTED_OUT,
					      READ_UNLOCK_NESTED_OUT);


			:: CONSUME_TOKENS(proc_urcu_reader,
					  READ_PROC_ACCESS_GEN		/* mb() orders reads */
					  | READ_PROC_READ_GEN		/* mb() orders reads */
					  | READ_PROC_FIRST_MB		/* mb() ordered */
					  | READ_LOCK_OUT		/* post-dominant */
					  | READ_LOCK_NESTED_OUT	/* post-dominant */
					  | READ_UNLOCK_NESTED_OUT,
					  READ_PROC_SECOND_MB) ->
				smp_mb_reader(i, j);
				PRODUCE_TOKENS(proc_urcu_reader, READ_PROC_SECOND_MB);

			PROCEDURE_READ_UNLOCK(READ_UNLOCK_BASE,
					      READ_PROC_SECOND_MB	/* mb() orders reads */
					      | READ_PROC_FIRST_MB	/* mb() orders reads */
					      | READ_LOCK_NESTED_OUT	/* RAW */
					      | READ_LOCK_OUT		/* RAW */
					      | READ_UNLOCK_NESTED_OUT,	/* RAW */
					      READ_UNLOCK_OUT);

			/* Unrolling loop : second consecutive lock */
			/* reading urcu_active_readers, which have been written by
			 * READ_UNLOCK_OUT : RAW */
			PROCEDURE_READ_LOCK(READ_LOCK_UNROLL_BASE,
					    READ_UNLOCK_OUT		/* RAW */
					    | READ_PROC_SECOND_MB	/* mb() orders reads */
					    | READ_PROC_FIRST_MB	/* mb() orders reads */
					    | READ_LOCK_NESTED_OUT	/* RAW */
					    | READ_LOCK_OUT		/* RAW */
					    | READ_UNLOCK_NESTED_OUT,	/* RAW */
					    READ_LOCK_OUT_UNROLL);


			:: CONSUME_TOKENS(proc_urcu_reader,
					  READ_PROC_FIRST_MB		/* mb() ordered */
					  | READ_PROC_SECOND_MB		/* mb() ordered */
					  | READ_LOCK_OUT_UNROLL	/* post-dominant */
					  | READ_LOCK_NESTED_OUT
					  | READ_LOCK_OUT
					  | READ_UNLOCK_NESTED_OUT
					  | READ_UNLOCK_OUT,
					  READ_PROC_THIRD_MB) ->
				smp_mb_reader(i, j);
				PRODUCE_TOKENS(proc_urcu_reader, READ_PROC_THIRD_MB);

			:: CONSUME_TOKENS(proc_urcu_reader,
					  READ_PROC_FIRST_MB		/* mb() orders reads */
					  | READ_PROC_SECOND_MB		/* mb() orders reads */
					  | READ_PROC_THIRD_MB,		/* mb() orders reads */
					  READ_PROC_READ_GEN_UNROLL) ->
				ooo_mem(i);
				ptr_read_second[get_readerid()] = READ_CACHED_VAR(rcu_ptr);
				PRODUCE_TOKENS(proc_urcu_reader, READ_PROC_READ_GEN_UNROLL);

			:: CONSUME_TOKENS(proc_urcu_reader,
					  READ_PROC_READ_GEN_UNROLL
					  | READ_PROC_FIRST_MB		/* mb() orders reads */
					  | READ_PROC_SECOND_MB		/* mb() orders reads */
					  | READ_PROC_THIRD_MB,		/* mb() orders reads */
					  READ_PROC_ACCESS_GEN_UNROLL) ->
				/* smp_read_barrier_depends */
				goto rmb2;
rmb2_end:
				data_read_second[get_readerid()] =
					READ_CACHED_VAR(rcu_data[ptr_read_second[get_readerid()]]);
				PRODUCE_TOKENS(proc_urcu_reader, READ_PROC_ACCESS_GEN_UNROLL);

			:: CONSUME_TOKENS(proc_urcu_reader,
					  READ_PROC_READ_GEN_UNROLL	/* mb() orders reads */
					  | READ_PROC_ACCESS_GEN_UNROLL	/* mb() orders reads */
					  | READ_PROC_FIRST_MB		/* mb() ordered */
					  | READ_PROC_SECOND_MB		/* mb() ordered */
					  | READ_PROC_THIRD_MB		/* mb() ordered */
					  | READ_LOCK_OUT_UNROLL	/* post-dominant */
					  | READ_LOCK_NESTED_OUT
					  | READ_LOCK_OUT
					  | READ_UNLOCK_NESTED_OUT
					  | READ_UNLOCK_OUT,
					  READ_PROC_FOURTH_MB) ->
				smp_mb_reader(i, j);
				PRODUCE_TOKENS(proc_urcu_reader, READ_PROC_FOURTH_MB);

			PROCEDURE_READ_UNLOCK(READ_UNLOCK_UNROLL_BASE,
					      READ_PROC_FOURTH_MB	/* mb() orders reads */
					      | READ_PROC_THIRD_MB	/* mb() orders reads */
					      | READ_LOCK_OUT_UNROLL	/* RAW */
					      | READ_PROC_SECOND_MB	/* mb() orders reads */
					      | READ_PROC_FIRST_MB	/* mb() orders reads */
					      | READ_LOCK_NESTED_OUT	/* RAW */
					      | READ_LOCK_OUT		/* RAW */
					      | READ_UNLOCK_NESTED_OUT,	/* RAW */
					      READ_UNLOCK_OUT_UNROLL);
			:: CONSUME_TOKENS(proc_urcu_reader, READ_PROC_ALL_TOKENS, 0) ->
				CLEAR_TOKENS(proc_urcu_reader, READ_PROC_ALL_TOKENS_CLEAR);
				break;
			fi;
		}
	od;
	/*
	 * Dependency between consecutive loops :
	 * RAW dependency on 
	 * WRITE_CACHED_VAR(urcu_active_readers[get_readerid()], tmp2 - 1)
	 * tmp = READ_CACHED_VAR(urcu_active_readers[get_readerid()]);
	 * between loops.
	 * _WHEN THE MB()s are in place_, they add full ordering of the
	 * generation pointer read wrt active reader count read, which ensures
	 * execution will not spill across loop execution.
	 * However, in the event mb()s are removed (execution using signal
	 * handler to promote barrier()() -> smp_mb()), nothing prevents one loop
	 * to spill its execution on other loop's execution.
	 */
	goto end;
rmb1:
#ifndef NO_RMB
	smp_rmb(i);
#else
	ooo_mem(i);
#endif
	goto rmb1_end;
rmb2:
#ifndef NO_RMB
	smp_rmb(i);
#else
	ooo_mem(i);
#endif
	goto rmb2_end;
end:
	skip;
}



active proctype urcu_reader()
{
	byte i, j, nest_i;
	byte tmp, tmp2;

	wait_init_done();

	assert(get_pid() < NR_PROCS);

end_reader:
	do
	:: 1 ->
		/*
		 * We do not test reader's progress here, because we are mainly
		 * interested in writer's progress. The reader never blocks
		 * anyway. We have to test for reader/writer's progress
		 * separately, otherwise we could think the writer is doing
		 * progress when it's blocked by an always progressing reader.
		 */
#ifdef READER_PROGRESS
progress_reader:
#endif
		urcu_one_read(i, j, nest_i, tmp, tmp2);
	od;
}

/* no name clash please */
#undef proc_urcu_reader


/* Model the RCU update process. */

/*
 * Bit encoding, urcu_writer :
 * Currently only supports one reader.
 */

int _proc_urcu_writer;
#define proc_urcu_writer	_proc_urcu_writer

#define WRITE_PROD_NONE			(1 << 0)

#define WRITE_DATA			(1 << 1)
#define WRITE_PROC_WMB			(1 << 2)
#define WRITE_XCHG_PTR			(1 << 3)

#define WRITE_PROC_FIRST_MB		(1 << 4)

/* first flip */
#define WRITE_PROC_FIRST_READ_GP	(1 << 5)
#define WRITE_PROC_FIRST_WRITE_GP	(1 << 6)
#define WRITE_PROC_FIRST_WAIT		(1 << 7)
#define WRITE_PROC_FIRST_WAIT_LOOP	(1 << 8)

/* second flip */
#define WRITE_PROC_SECOND_READ_GP	(1 << 9)
#define WRITE_PROC_SECOND_WRITE_GP	(1 << 10)
#define WRITE_PROC_SECOND_WAIT		(1 << 11)
#define WRITE_PROC_SECOND_WAIT_LOOP	(1 << 12)

#define WRITE_PROC_SECOND_MB		(1 << 13)

#define WRITE_FREE			(1 << 14)

#define WRITE_PROC_ALL_TOKENS		(WRITE_PROD_NONE		\
					| WRITE_DATA			\
					| WRITE_PROC_WMB		\
					| WRITE_XCHG_PTR		\
					| WRITE_PROC_FIRST_MB		\
					| WRITE_PROC_FIRST_READ_GP	\
					| WRITE_PROC_FIRST_WRITE_GP	\
					| WRITE_PROC_FIRST_WAIT		\
					| WRITE_PROC_SECOND_READ_GP	\
					| WRITE_PROC_SECOND_WRITE_GP	\
					| WRITE_PROC_SECOND_WAIT	\
					| WRITE_PROC_SECOND_MB		\
					| WRITE_FREE)

#define WRITE_PROC_ALL_TOKENS_CLEAR	((1 << 15) - 1)

/*
 * Mutexes are implied around writer execution. A single writer at a time.
 */
active proctype urcu_writer()
{
	byte i, j;
	byte tmp, tmp2, tmpa;
	byte cur_data = 0, old_data, loop_nr = 0;
	byte cur_gp_val = 0;	/*
				 * Keep a local trace of the current parity so
				 * we don't add non-existing dependencies on the global
				 * GP update. Needed to test single flip case.
				 */

	wait_init_done();

	assert(get_pid() < NR_PROCS);

	do
	:: (loop_nr < 3) ->
#ifdef WRITER_PROGRESS
progress_writer1:
#endif
		loop_nr = loop_nr + 1;

		PRODUCE_TOKENS(proc_urcu_writer, WRITE_PROD_NONE);

#ifdef NO_WMB
		PRODUCE_TOKENS(proc_urcu_writer, WRITE_PROC_WMB);
#endif

#ifdef NO_MB
		PRODUCE_TOKENS(proc_urcu_writer, WRITE_PROC_FIRST_MB);
		PRODUCE_TOKENS(proc_urcu_writer, WRITE_PROC_SECOND_MB);
#endif

#ifdef SINGLE_FLIP
		PRODUCE_TOKENS(proc_urcu_writer, WRITE_PROC_SECOND_READ_GP);
		PRODUCE_TOKENS(proc_urcu_writer, WRITE_PROC_SECOND_WRITE_GP);
		PRODUCE_TOKENS(proc_urcu_writer, WRITE_PROC_SECOND_WAIT);
		/* For single flip, we need to know the current parity */
		cur_gp_val = cur_gp_val ^ RCU_GP_CTR_BIT;
#endif

		do :: 1 ->
		atomic {
		if

		:: CONSUME_TOKENS(proc_urcu_writer,
				  WRITE_PROD_NONE,
				  WRITE_DATA) ->
			ooo_mem(i);
			cur_data = (cur_data + 1) % SLAB_SIZE;
			WRITE_CACHED_VAR(rcu_data[cur_data], WINE);
			PRODUCE_TOKENS(proc_urcu_writer, WRITE_DATA);


		:: CONSUME_TOKENS(proc_urcu_writer,
				  WRITE_DATA,
				  WRITE_PROC_WMB) ->
			smp_wmb(i);
			PRODUCE_TOKENS(proc_urcu_writer, WRITE_PROC_WMB);

		:: CONSUME_TOKENS(proc_urcu_writer,
				  WRITE_PROC_WMB,
				  WRITE_XCHG_PTR) ->
			/* rcu_xchg_pointer() */
			atomic {
				old_data = READ_CACHED_VAR(rcu_ptr);
				WRITE_CACHED_VAR(rcu_ptr, cur_data);
			}
			PRODUCE_TOKENS(proc_urcu_writer, WRITE_XCHG_PTR);

		:: CONSUME_TOKENS(proc_urcu_writer,
				  WRITE_DATA | WRITE_PROC_WMB | WRITE_XCHG_PTR,
				  WRITE_PROC_FIRST_MB) ->
			goto smp_mb_send1;
smp_mb_send1_end:
			PRODUCE_TOKENS(proc_urcu_writer, WRITE_PROC_FIRST_MB);

		/* first flip */
		:: CONSUME_TOKENS(proc_urcu_writer,
				  WRITE_PROC_FIRST_MB,
				  WRITE_PROC_FIRST_READ_GP) ->
			tmpa = READ_CACHED_VAR(urcu_gp_ctr);
			PRODUCE_TOKENS(proc_urcu_writer, WRITE_PROC_FIRST_READ_GP);
		:: CONSUME_TOKENS(proc_urcu_writer,
				  WRITE_PROC_FIRST_MB | WRITE_PROC_WMB
				  | WRITE_PROC_FIRST_READ_GP,
				  WRITE_PROC_FIRST_WRITE_GP) ->
			ooo_mem(i);
			WRITE_CACHED_VAR(urcu_gp_ctr, tmpa ^ RCU_GP_CTR_BIT);
			PRODUCE_TOKENS(proc_urcu_writer, WRITE_PROC_FIRST_WRITE_GP);

		:: CONSUME_TOKENS(proc_urcu_writer,
				  //WRITE_PROC_FIRST_WRITE_GP	/* TEST ADDING SYNC CORE */
				  WRITE_PROC_FIRST_MB,	/* can be reordered before/after flips */
				  WRITE_PROC_FIRST_WAIT | WRITE_PROC_FIRST_WAIT_LOOP) ->
			ooo_mem(i);
			/* ONLY WAITING FOR READER 0 */
			tmp2 = READ_CACHED_VAR(urcu_active_readers[0]);
#ifndef SINGLE_FLIP
			/* In normal execution, we are always starting by
			 * waiting for the even parity.
			 */
			cur_gp_val = RCU_GP_CTR_BIT;
#endif
			if
			:: (tmp2 & RCU_GP_CTR_NEST_MASK)
					&& ((tmp2 ^ cur_gp_val) & RCU_GP_CTR_BIT) ->
				PRODUCE_TOKENS(proc_urcu_writer, WRITE_PROC_FIRST_WAIT_LOOP);
			:: else	->
				PRODUCE_TOKENS(proc_urcu_writer, WRITE_PROC_FIRST_WAIT);
			fi;

		:: CONSUME_TOKENS(proc_urcu_writer,
				  //WRITE_PROC_FIRST_WRITE_GP	/* TEST ADDING SYNC CORE */
				  WRITE_PROC_FIRST_WRITE_GP
				  | WRITE_PROC_FIRST_READ_GP
				  | WRITE_PROC_FIRST_WAIT_LOOP
				  | WRITE_DATA | WRITE_PROC_WMB | WRITE_XCHG_PTR
				  | WRITE_PROC_FIRST_MB,	/* can be reordered before/after flips */
				  0) ->
#ifndef GEN_ERROR_WRITER_PROGRESS
			goto smp_mb_send2;
smp_mb_send2_end:
#else
			ooo_mem(i);
#endif
			/* This instruction loops to WRITE_PROC_FIRST_WAIT */
			CLEAR_TOKENS(proc_urcu_writer, WRITE_PROC_FIRST_WAIT_LOOP | WRITE_PROC_FIRST_WAIT);

		/* second flip */
		:: CONSUME_TOKENS(proc_urcu_writer,
				  WRITE_PROC_FIRST_WAIT		/* Control dependency : need to branch out of
								 * the loop to execute the next flip (CHECK) */
				  | WRITE_PROC_FIRST_WRITE_GP
				  | WRITE_PROC_FIRST_READ_GP
				  | WRITE_PROC_FIRST_MB,
				  WRITE_PROC_SECOND_READ_GP) ->
			ooo_mem(i);
			tmpa = READ_CACHED_VAR(urcu_gp_ctr);
			PRODUCE_TOKENS(proc_urcu_writer, WRITE_PROC_SECOND_READ_GP);
		:: CONSUME_TOKENS(proc_urcu_writer,
				  WRITE_PROC_FIRST_MB
				  | WRITE_PROC_WMB
				  | WRITE_PROC_FIRST_READ_GP
				  | WRITE_PROC_FIRST_WRITE_GP
				  | WRITE_PROC_SECOND_READ_GP,
				  WRITE_PROC_SECOND_WRITE_GP) ->
			ooo_mem(i);
			WRITE_CACHED_VAR(urcu_gp_ctr, tmpa ^ RCU_GP_CTR_BIT);
			PRODUCE_TOKENS(proc_urcu_writer, WRITE_PROC_SECOND_WRITE_GP);

		:: CONSUME_TOKENS(proc_urcu_writer,
				  //WRITE_PROC_FIRST_WRITE_GP	/* TEST ADDING SYNC CORE */
				  WRITE_PROC_FIRST_WAIT
				  | WRITE_PROC_FIRST_MB,	/* can be reordered before/after flips */
				  WRITE_PROC_SECOND_WAIT | WRITE_PROC_SECOND_WAIT_LOOP) ->
			ooo_mem(i);
			/* ONLY WAITING FOR READER 0 */
			tmp2 = READ_CACHED_VAR(urcu_active_readers[0]);
			if
			:: (tmp2 & RCU_GP_CTR_NEST_MASK)
					&& ((tmp2 ^ 0) & RCU_GP_CTR_BIT) ->
				PRODUCE_TOKENS(proc_urcu_writer, WRITE_PROC_SECOND_WAIT_LOOP);
			:: else	->
				PRODUCE_TOKENS(proc_urcu_writer, WRITE_PROC_SECOND_WAIT);
			fi;

		:: CONSUME_TOKENS(proc_urcu_writer,
				  //WRITE_PROC_FIRST_WRITE_GP	/* TEST ADDING SYNC CORE */
				  WRITE_PROC_SECOND_WRITE_GP
				  | WRITE_PROC_FIRST_WRITE_GP
				  | WRITE_PROC_SECOND_READ_GP
				  | WRITE_PROC_FIRST_READ_GP
				  | WRITE_PROC_SECOND_WAIT_LOOP
				  | WRITE_DATA | WRITE_PROC_WMB | WRITE_XCHG_PTR
				  | WRITE_PROC_FIRST_MB,	/* can be reordered before/after flips */
				  0) ->
#ifndef GEN_ERROR_WRITER_PROGRESS
			goto smp_mb_send3;
smp_mb_send3_end:
#else
			ooo_mem(i);
#endif
			/* This instruction loops to WRITE_PROC_SECOND_WAIT */
			CLEAR_TOKENS(proc_urcu_writer, WRITE_PROC_SECOND_WAIT_LOOP | WRITE_PROC_SECOND_WAIT);


		:: CONSUME_TOKENS(proc_urcu_writer,
				  WRITE_PROC_FIRST_WAIT
				  | WRITE_PROC_SECOND_WAIT
				  | WRITE_PROC_FIRST_READ_GP
				  | WRITE_PROC_SECOND_READ_GP
				  | WRITE_PROC_FIRST_WRITE_GP
				  | WRITE_PROC_SECOND_WRITE_GP
				  | WRITE_DATA | WRITE_PROC_WMB | WRITE_XCHG_PTR
				  | WRITE_PROC_FIRST_MB,
				  WRITE_PROC_SECOND_MB) ->
			goto smp_mb_send4;
smp_mb_send4_end:
			PRODUCE_TOKENS(proc_urcu_writer, WRITE_PROC_SECOND_MB);

		:: CONSUME_TOKENS(proc_urcu_writer,
				  WRITE_XCHG_PTR
				  | WRITE_PROC_FIRST_WAIT
				  | WRITE_PROC_SECOND_WAIT
				  | WRITE_PROC_WMB	/* No dependency on
							 * WRITE_DATA because we
							 * write to a
							 * different location. */
				  | WRITE_PROC_SECOND_MB
				  | WRITE_PROC_FIRST_MB,
				  WRITE_FREE) ->
			WRITE_CACHED_VAR(rcu_data[old_data], POISON);
			PRODUCE_TOKENS(proc_urcu_writer, WRITE_FREE);

		:: CONSUME_TOKENS(proc_urcu_writer, WRITE_PROC_ALL_TOKENS, 0) ->
			CLEAR_TOKENS(proc_urcu_writer, WRITE_PROC_ALL_TOKENS_CLEAR);
			break;
		fi;
		}
		od;
		/*
		 * Note : Promela model adds implicit serialization of the
		 * WRITE_FREE instruction. Normally, it would be permitted to
		 * spill on the next loop execution. Given the validation we do
		 * checks for the data entry read to be poisoned, it's ok if
		 * we do not check "late arriving" memory poisoning.
		 */
	:: else -> break;
	od;
	/*
	 * Given the reader loops infinitely, let the writer also busy-loop
	 * with progress here so, with weak fairness, we can test the
	 * writer's progress.
	 */
end_writer:
	do
	:: 1 ->
#ifdef WRITER_PROGRESS
progress_writer2:
#endif
#ifdef READER_PROGRESS
		/*
		 * Make sure we don't block the reader's progress.
		 */
		smp_mb_send(i, j, 5);
#endif
		skip;
	od;

	/* Non-atomic parts of the loop */
	goto end;
smp_mb_send1:
	smp_mb_send(i, j, 1);
	goto smp_mb_send1_end;
#ifndef GEN_ERROR_WRITER_PROGRESS
smp_mb_send2:
	smp_mb_send(i, j, 2);
	goto smp_mb_send2_end;
smp_mb_send3:
	smp_mb_send(i, j, 3);
	goto smp_mb_send3_end;
#endif
smp_mb_send4:
	smp_mb_send(i, j, 4);
	goto smp_mb_send4_end;
end:
	skip;
}

/* no name clash please */
#undef proc_urcu_writer


/* Leave after the readers and writers so the pid count is ok. */
init {
	byte i, j;

	atomic {
		INIT_CACHED_VAR(urcu_gp_ctr, 1, j);
		INIT_CACHED_VAR(rcu_ptr, 0, j);

		i = 0;
		do
		:: i < NR_READERS ->
			INIT_CACHED_VAR(urcu_active_readers[i], 0, j);
			ptr_read_first[i] = 1;
			ptr_read_second[i] = 1;
			data_read_first[i] = WINE;
			data_read_second[i] = WINE;
			i++;
		:: i >= NR_READERS -> break
		od;
		INIT_CACHED_VAR(rcu_data[0], WINE, j);
		i = 1;
		do
		:: i < SLAB_SIZE ->
			INIT_CACHED_VAR(rcu_data[i], POISON, j);
			i++
		:: i >= SLAB_SIZE -> break
		od;

		init_done = 1;
	}
}
